#include "MainWindow.hpp"
#include "LibraryStore.hpp"
#include "LibraryDialog.hpp"
#include "SemanticHtml.hpp"
#include "MediaPanel.hpp"
#include "SemanticFigure.hpp"
#include "InlineVectorImages.hpp"
#include "CompiledContent.hpp"
#include "LogicalFlow.hpp"
#include "FlowConstruction.hpp"
#include "FigureSizing.hpp"
#include "ParagraphBox.hpp"
#include "ParagraphProjection.hpp"

#include <QAbstractTextDocumentLayout>
#include <QAccessible>
#include <QApplication>
#include <QMimeData>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QCheckBox>
#include <QStandardPaths>
#include <QCryptographicHash>
#include <QBuffer>
#include <QAction>
#include <QComboBox>
#include <QClipboard>
#include <QCloseEvent>
#include <QHelpEvent>
#include <QToolTip>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QFontMetricsF>
#include <QGridLayout>
#include <QGlyphRun>
#include <QPainterPath>
#include <QPainter>
#include <QImage>
#include <QImageReader>
#include <QItemSelectionModel>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QMenu>
#include <QStatusBar>
#include <QStyleOption>
#include <QPalette>
#include <QPointer>
#include <QProgressBar>
#include <QPushButton>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QScrollArea>
#include <QScrollBar>
#include <QScreen>
#include <QWindow>
#include <QSpinBox>
#include <QSet>
#include <QSettings>
#include <QSemaphore>
#include <QThreadPool>
#include <QTreeWidget>
#include <QtConcurrent/QtConcurrentRun>
#include <QStackedWidget>
#include <QStringList>
#include <QTabBar>
#include <QTabWidget>
#include <QToolBar>
#include <QSplitter>
#include <QTemporaryDir>
#include <QTextBlock>
#include <QTextBrowser>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextDocumentFragment>
#include <QTextFragment>
#include <QTextLayout>
#include <QTextTable>
#include <QTimer>
#include <QUrl>
#include <QtTest>
#include <limits>
#include <memory>
#include <algorithm>
#include <array>

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
            if (block.charFormat().anchorNames().contains(name)) return true;
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

    static bool prepareCaseTitleFixture(const QString &fixtureRoot, const QString &directory, QStringList titles,
                                        const QByteArray &code = QByteArrayLiteral("en"),
                                        const QByteArray &heading = QByteArrayLiteral("English"), bool distinctBody = false) {
        QFile fixture(fixtureRoot + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
        if (!fixture.open(QIODevice::ReadOnly)) return false;
        const QByteArray original = fixture.readAll();
        qsizetype at = 9;
        for (int i = 0; i < 3; ++i) {
            at = original.indexOf('\0', at) + 1;
            if (at <= 0) return false;
        }
        const qsizetype lengthStart = at;
        quint64 length = 0;
        for (int shift = 0; ; shift += 7) {
            if (at >= original.size() || shift >= 64) return false;
            const auto byte = static_cast<unsigned char>(original[at++]);
            length |= quint64(byte & 127) << shift;
            if (!(byte & 128)) break;
        }
        if (length > quint64(original.size() - at)) return false;
        QByteArray record = original.mid(lengthStart, at - lengthStart + qsizetype(length));
        if (distinctBody) {
            // Equal-length fixture text keeps the existing compiled record framing intact.
            if (record.count("A small animal.") != 1) return false;
            record.replace("A small animal.", "A river animal.");
        }
        std::sort(titles.begin(), titles.end(), [](const QString &left, const QString &right) {
            return left.toUtf8() < right.toUtf8();
        });
        QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(1) + code + '\0' + heading + '\0';
        for (const QString &word : titles) bytes += word.toUtf8() + '\0' + record;
        const QString source = directory + QStringLiteral("/source.wikblb");
        QFile file(source);
        if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size()) return false;
        file.close();
        std::atomic_bool cancelled = false;
        const QString root = directory + QStringLiteral("/library");
        auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        return true;
    }

    static QJsonObject qichwaReferenceShape() {
        // Synthetic control with the retained qichwa section order, empty leaf,
        // multiline example and separately stored references. Not a corpus fixture.
        return QJsonDocument::fromJson(
            "{\n"
            "          \"title\":\"qichwa\", \"kind\":\"language\", \"language\":\"Quechua\",\n"
            "          \"preamble_spans\":[\n"
            "            {\"kind\":\"link\",\"text\":\"Go to list\",\"target\":\"#References\"},\n"
            "            {\"kind\":\"text\",\"text\":\" | \"},\n"
            "            {\"kind\":\"link\",\"text\":\"Go to second source\",\"target\":\"#reference-2\"}\n"
            "          ],\n"
            "          \"sections\":[\n"
            "            {\"level\":2,\"title\":\"Quechua\",\"anchor\":\"Quechua\",\"blocks\":[]},\n"
            "            {\"level\":3,\"title\":\"Alternative forms\",\"blocks\":[]},\n"
            "            {\"level\":3,\"title\":\"Etymology\",\"blocks\":[]},\n"
            "            {\"level\":3,\"title\":\"Pronunciation\",\"blocks\":[]},\n"
            "            {\"level\":3,\"title\":\"Noun\",\"blocks\":[\n"
            "              {\"kind\":\"example\",\"depth\":2,\"spans\":[\n"
            "                {\"kind\":\"link\",\"text\":\"Ñuqanchik\",\"target\":\"ñuqanchik#Quechua\",\"italic\":true},\n"
            "                {\"kind\":\"text\",\"text\":\" \",\"italic\":true},\n"
            "                {\"kind\":\"text\",\"text\":\"qhichwa\",\"bold\":true,\"italic\":true},\n"
            "                {\"kind\":\"text\",\"text\":\" simita rimachkanchik.\",\"italic\":true},\n"
            "                {\"kind\":\"line_break\",\"text\":\"\\n\"},\n"
            "                {\"kind\":\"text\",\"text\":\"We are speaking \"},\n"
            "                {\"kind\":\"text\",\"text\":\"Quechua (language)\",\"bold\":true},\n"
            "                {\"kind\":\"text\",\"text\":\".\"},\n"
            "                {\"kind\":\"line_break\",\"text\":\"\\n\"},\n"
            "                {\"kind\":\"line_break\",\"text\":\"\\n\"}\n"
            "              ]}\n"
            "            ]},\n"
            "            {\"level\":4,\"title\":\"Declension\",\"blocks\":[]},\n"
            "            {\"level\":4,\"title\":\"See also\",\"blocks\":[]},\n"
            "            {\"level\":3,\"title\":\"References\",\"anchor\":\"References\",\"blocks\":[]},\n"
            "            {\"level\":3,\"title\":\"Further reading\",\"blocks\":[\n"
            "              {\"kind\":\"paragraph\",\"spans\":[{\"kind\":\"text\",\"text\":\"Further reading before the reference list.\"}]},\n"
            "              {\"kind\":\"paragraph\",\"spans\":[{\"kind\":\"text\",\"text\":\"Further reading continues here.\"}]},\n"
            "              {\"kind\":\"paragraph\",\"spans\":[{\"kind\":\"text\",\"text\":\"Last further-reading marker.\"}]}\n"
            "            ]}\n"
            "          ],\n"
            "          \"references\":[\n"
            "            {\"number\":1,\"group_number\":1,\"group\":\"\",\"spans\":[{\"kind\":\"text\",\"text\":\"Reference one proof.\"}]},\n"
            "            {\"number\":2,\"group_number\":2,\"group\":\"\",\"spans\":[{\"kind\":\"text\",\"text\":\"Reference two proof.\"}]}\n"
            "          ]\n"
            "        }").object();
    }

private slots:
    void emptyHeadingKeepsWrappedTitleAndSubtitleSeparate() {
        // Ordinary empty-library state; no title rewrite or synthetic body entry.
        MainWindow window{QString()};
        window.resize(900, 640); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        QCOMPARE(window.title_->toPlainText(), QStringLiteral("Open your dictionaries"));
        QCOMPARE(window.meta_->text(), QStringLiteral("Your words stay on this computer."));
        QVERIFY(!window.api_);
        const QString titleText = window.title_->toPlainText();
        const QString metaText = window.meta_->text();
        QJsonArray observations;
        const QString stem = QStringLiteral(".tmp/ui-screenshots/empty-heading-%1")
            .arg(QCoreApplication::applicationPid());
        QDir().mkpath(QStringLiteral(".tmp/ui-screenshots"));
        const auto save = qScopeGuard([&] {
            QFile file(stem + QStringLiteral(".json"));
            if (file.open(QIODevice::WriteOnly))
                file.write(QJsonDocument(QJsonObject{{"observations", observations}}).toJson());
        });
        const auto rect = [](const QRectF &r) {
            return QJsonArray{r.x(), r.y(), r.width(), r.height()};
        };
        const auto windowRect = [&](const QWidget *widget) {
            return QRect(widget->mapTo(&window, QPoint()), widget->size());
        };
        const auto allocation = [&] {
            auto *heading = window.readerHeading_->layout();
            return QJsonObject{
                {"title", rect(windowRect(window.title_))},
                {"viewport", rect(windowRect(window.title_->viewport()))},
                {"meta", rect(windowRect(window.meta_))},
                {"heading", rect(windowRect(window.readerHeading_))},
                {"tabs", rect(windowRect(window.entryTabs_))},
                {"content", rect(windowRect(window.readerContent_))},
                {"title_min_height", window.title_->minimumHeight()},
                {"title_max_height", window.title_->maximumHeight()},
                {"heading_layout_local", rect(heading->geometry())},
                {"title_item_local", rect(heading->itemAt(0)->geometry())},
                {"meta_item_local", rect(heading->itemAt(1)->geometry())},
                {"heading_spacing", heading->spacing()},
                {"compact_reader", window.compactReader_},
                {"compact_header", window.compactHeader_}};
        };
        const auto measure = [&](int requestedWidth, const QString &phase, int eventTurns) {
            // Preserve allocation before forcing documentSize: observation itself
            // may finish lazy text layout, and must not hide that distinction.
            const QJsonObject before = allocation();
            auto *document = window.title_->document();
            const QSizeF page = document->pageSize();
            const QSizeF size = document->size();
            QJsonArray blocks;
            qreal lineBottom = 0;
            for (auto block = document->begin(); block.isValid(); block = block.next()) {
                const QRectF blockRect = document->documentLayout()->blockBoundingRect(block);
                QJsonArray lines;
                if (auto *layout = block.layout()) {
                    for (int i = 0; i < layout->lineCount(); ++i) {
                        const auto line = layout->lineAt(i);
                        const QRectF lineRect = line.rect().translated(blockRect.topLeft());
                        lineBottom = qMax(lineBottom, lineRect.bottom());
                        lines.append(QJsonObject{{"start", line.textStart()}, {"length", line.textLength()},
                            {"rect_document", rect(lineRect)}, {"ascent", line.ascent()},
                            {"descent", line.descent()}, {"leading", line.leading()}});
                    }
                }
                blocks.append(QJsonObject{{"position", block.position()}, {"text", block.text()},
                    {"rect_document", rect(blockRect)}, {"lines", lines}});
            }
            const QRect title = windowRect(window.title_);
            const QRect viewport = windowRect(window.title_->viewport());
            const QRect meta = windowRect(window.meta_);
            const QRect heading = windowRect(window.readerHeading_);
            const QRect tabs = windowRect(window.entryTabs_);
            const bool documentFits = size.height() <= viewport.height()
                && lineBottom <= viewport.height();
            const bool siblingsSeparate = title.y() + title.height() <= meta.y();
            const bool headerFits = title.y() >= heading.y() && meta.y() >= heading.y()
                && title.y() + title.height() <= heading.y() + heading.height()
                && meta.y() + meta.height() <= heading.y() + heading.height();
            const bool tabsSeparate = heading.y() + heading.height() <= tabs.y();
            QJsonObject result{{"requested_width", requestedWidth}, {"phase", phase},
                {"event_turns", eventTurns}, {"allocation_before_document_query", before},
                {"allocation_after_document_query", allocation()},
                {"document_size", QJsonArray{size.width(), size.height()}},
                {"document_page_size", QJsonArray{page.width(), page.height()}},
                {"document_margin", document->documentMargin()},
                {"document_text_width", document->textWidth()},
                {"font_points", window.title_->font().pointSizeF()},
                {"document_font_points", document->defaultFont().pointSizeF()},
                {"viewport_contents", rect(window.title_->viewport()->contentsRect())},
                {"vertical_scroll", window.title_->verticalScrollBar()->value()},
                {"horizontal_scroll", window.title_->horizontalScrollBar()->value()},
                {"blocks", blocks}, {"document_fits", documentFits},
                {"siblings_separate", siblingsSeparate}, {"header_fits", headerFits},
                {"tabs_separate", tabsSeparate}};
            observations.append(result);
            return documentFits && siblingsSeparate && headerFits && tabsSeparate;
        };
        bool allSettledBoundsPass = true;
        bool allSettled = true;
        int iteration = 0;
        for (int width : {900, 640, 900}) {
            window.resize(width, 640);
            QCOMPARE(window.width(), width);
            QTRY_COMPARE(window.compactNavigation_, width < 720);
            // Select the ordinary Reading action; compact empty state may carry
            // Search focus and intentionally hide the reader after resizing.
            window.readingPaneAction_->trigger();
            QTRY_VERIFY(window.readerContent_->isVisible() && window.reading_->isVisible());
            QVERIFY(!window.compactSearchPane_);
            measure(width, QStringLiteral("immediate"), 0);
            // Sample distinct event-loop turns, without calling activate(),
            // resizing the title, or otherwise repairing the observed layout.
            QJsonObject previous = allocation();
            int stableTurns = 0, turns = 0;
            for (; turns < 25 && stableTurns < 2; ++turns) {
                QTest::qWait(20);
                const auto current = allocation();
                stableTurns = current == previous ? stableTurns + 1 : 0;
                previous = current;
            }
            allSettled &= stableTurns >= 2;
            allSettledBoundsPass &= measure(width, QStringLiteral("settled"), turns);
            QCOMPARE(window.title_->toPlainText(), titleText);
            QCOMPARE(window.meta_->text(), metaText);
            QVERIFY(window.title_->isVisible() && window.meta_->isVisible());
            QVERIFY(window.grab().save(stem + QStringLiteral("-%1-%2.png").arg(iteration++).arg(width)));
        }
        // Retain all three widths before the strict failure, including a stable
        // overlapping allocation if one exists. No adjacent-pixel tolerance.
        QVERIFY(allSettled);
        QVERIFY(allSettledBoundsPass);
    }

    void typedInlineImageBorderRequiresBoolean() {
        const QJsonObject absent{{"file", "Flag fixture.svg"}, {"width_px", 40}};
        QCOMPARE(SemanticHtml::checkedImage(absent), absent);
        for (bool value : {false, true}) {
            QJsonObject image = absent; image.insert("border", value);
            QCOMPARE(SemanticHtml::inlineImageData(SemanticHtml::inlineImageUrl(image)), image);
        }
        for (const QJsonValue &value : {QJsonValue(QJsonValue::Null), QJsonValue(1), QJsonValue("true"), QJsonValue(QJsonObject{})}) {
            QJsonObject image = absent; image.insert("border", value);
            QVERIFY_EXCEPTION_THROWN(SemanticHtml::inlineImageHtml(image), std::runtime_error);
        }
    }

    void inlineImageBorderPaintsOutsideContent_data() {
        QTest::addColumn<bool>("vectorPayload");
        QTest::addColumn<int>("borderMode"); // 0 absent, 1 explicit false, 2 true.
        QTest::newRow("svg-absent") << true << 0;
        QTest::newRow("svg-false") << true << 1;
        QTest::newRow("svg-border") << true << 2;
        QTest::newRow("png-absent") << false << 0;
        QTest::newRow("png-false") << false << 1;
        QTest::newRow("png-border") << false << 2;
    }

    void inlineImageBorderPaintsOutsideContent() {
        QFETCH(bool, vectorPayload); QFETCH(int, borderMode);
        const bool border = borderMode == 2;
        QSettings().setValue("media/allowImages", false);
        QSettings().setValue("media/cacheMb", 10);
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(900, 700); window.show();
        const QString file = vectorPayload ? QStringLiteral("Border fixture.svg") : QStringLiteral("Border fixture.png");
        const QString host = LibraryStorage::sourceHost(window.api_->root());
        const QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/media-v1");
        QVERIFY(QDir().mkpath(cache));
        const QString key = QString::fromLatin1(QCryptographicHash::hash((host + ":image:" + file).toUtf8(), QCryptographicHash::Sha256).toHex());
        const QString payloadPath = cache + '/' + key + ".bin", metadataPath = cache + '/' + key + ".json";
        const auto removeFixture = qScopeGuard([&] { QFile::remove(payloadPath); QFile::remove(metadataPath); });
        const QColor ink(0xd1, 0x3a, 0x30);
        if (vectorPayload) {
            const QByteArray svg = R"svg(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10" viewBox="0 0 20 10"><rect width="20" height="10" fill="#d13a30"/></svg>)svg";
            QFile payload(payloadPath); QVERIFY(payload.open(QIODevice::WriteOnly)); QCOMPARE(payload.write(svg), svg.size());
        } else {
            QImage raster(20, 10, QImage::Format_ARGB32_Premultiplied); raster.fill(ink);
            QVERIFY(raster.save(payloadPath, "PNG"));
        }
        const QJsonObject assetMetadata{{"url", "https://upload.wikimedia.org/wikipedia/commons/a/owned-border-fixture"},
            {"source", "https://commons.wikimedia.org/wiki/File:" + file}, {"credit", "Owned border fixture"},
            {"intrinsic_width", 20}, {"intrinsic_height", 10}, {"original_mime", vectorPayload ? "image/svg+xml" : "image/png"}};
        QFile metadata(metadataPath); QVERIFY(metadata.open(QIODevice::WriteOnly));
        const QByteArray metadataBytes = QJsonDocument(assetMetadata).toJson(QJsonDocument::Compact);
        QCOMPARE(metadata.write(metadataBytes), metadataBytes.size()); metadata.close();
        QJsonObject image{{"file", file}, {"width_px", 40}, {"height_px", QJsonValue::Null}, {"alt", ""}, {"tooltip", "Border tooltip"}};
        if (borderMode != 0) image.insert("border", border);
        const QJsonObject linked{{"kind", "link"}, {"text", ""}, {"target", "File:" + file},
            {"bold", true}, {"italic", true}, {"foreground", "#123456"}, {"image", image}};
        QJsonObject decorative = linked; decorative.insert("kind", "text"); decorative.insert("target", "");
        const QJsonObject section{{"level", 2}, {"title", "Outside image border"}, {"blocks", QJsonArray{
            QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{linked}}},
            QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{decorative}}}}}};
        const QJsonObject entry{{"title", "Owned border fixture"}, {"kind", "language"}, {"language", window.api_->language()},
            {"sections", QJsonArray{section}}, {"media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", file}, {"caption", "Owned cached image"}}}}};
        const auto render = [&](const QJsonObject &value) {
            window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{value}}}).toJson(), false);
        };
        const auto images = [&] {
            QList<QPair<int, QTextImageFormat>> result;
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const auto fragment = it.fragment();
                    if (fragment.charFormat().isImageFormat()) result.append(qMakePair(fragment.position(), fragment.charFormat().toImageFormat()));
                }
            return result;
        };
        render(entry);
        QCOMPARE(images().size(), 2);
        QCOMPARE(images().first().second.intProperty(SemanticHtml::inlineImageStateProperty), int(MediaPanel::InlineImageState::Loading));
        QTRY_COMPARE(images().first().second.intProperty(SemanticHtml::inlineImageStateProperty), int(MediaPanel::InlineImageState::Disabled));
        auto *document = window.reading_->document();
        auto *handler = document->documentLayout()->handlerForObject(QTextFormat::ImageObject); QVERIFY(handler);
        auto sample = images().first();
        QCOMPARE(sample.second.width(), 40.0); QCOMPARE(sample.second.height(), 40.0);
        QCOMPARE(handler->intrinsicSize(document, sample.first, sample.second), border ? QSizeF(42, 42) : QSizeF(40, 40));
        auto *permission = window.media_->findChild<QCheckBox *>("mediaAllowImages"); QVERIFY(permission); permission->setChecked(true);
        const auto ready = [&] {
            const auto current = images();
            return current.size() == 2 && std::all_of(current.cbegin(), current.cend(), [](const auto &item) {
                return item.second.intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Ready);
            });
        };
        QTRY_VERIFY_WITH_TIMEOUT(ready(), 10000);
        const auto formats = images(); sample = formats.first();
        for (const auto &item : formats) {
            QCOMPARE(item.second.width(), 40.0); QCOMPARE(item.second.height(), 20.0);
            QCOMPARE(item.second.boolProperty(SemanticHtml::inlineImageBorderProperty), border);
            if (!border) QVERIFY(!item.second.hasProperty(SemanticHtml::inlineImageBorderProperty));
            QCOMPARE(item.second.stringProperty(QTextFormat::ImageAltText), QString());
            QVERIFY(item.second.hasProperty(QTextFormat::ImageAltText));
            QCOMPARE(item.second.toolTip(), QStringLiteral("Border tooltip"));
            QVERIFY(item.second.fontWeight() >= QFont::Bold); QVERIFY(item.second.fontItalic());
            QCOMPARE(item.second.foreground().color(), QColor("#123456"));
            QCOMPARE(handler->intrinsicSize(document, item.first, item.second), border ? QSizeF(42, 22) : QSizeF(40, 20));
        }
        QCOMPARE(QUrl(formats[0].second.anchorHref()).scheme(), QStringLiteral("media-source"));
        QCOMPARE(QUrl(formats[0].second.anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("File:") + file);
        QVERIFY(formats[0].second.isAnchor()); QVERIFY(!formats[1].second.isAnchor()); QVERIFY(formats[1].second.anchorHref().isEmpty());
        QCOMPARE(window.currentEntry_, entry);
        // Paint through the actual normal document handler, with its ready media
        // asset, into exact device-pixel canvases. No new decoder or test painter.
        const QSizeF outerSize = handler->intrinsicSize(document, sample.first, sample.second);
        const QRectF outerRect(QPointF(2, 2), outerSize);
        const QRectF contentRect(QPointF(border ? 3 : 2, border ? 3 : 2), QSizeF(40, 20));
        const QColor background(0x13, 0x4f, 0x61), borderColor(0xea, 0xec, 0xf0);
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        for (int dpr : {1, 2}) {
            const QSize pixels(qRound((outerSize.width() + 4) * dpr), qRound((outerSize.height() + 4) * dpr));
            QImage actual(pixels, QImage::Format_ARGB32_Premultiplied); actual.setDevicePixelRatio(dpr); actual.fill(background);
            { QPainter painter(&actual); handler->drawObject(&painter, outerRect, document, sample.first, sample.second); }
            QImage expected(pixels, QImage::Format_ARGB32_Premultiplied); expected.setDevicePixelRatio(dpr);
            qsizetype mismatched = 0, borderPixels = 0, contentPixels = 0;
            for (int y = 0; y < pixels.height(); ++y) for (int x = 0; x < pixels.width(); ++x) {
                const QPointF logical((x + 0.5) / dpr, (y + 0.5) / dpr);
                const QColor wanted = contentRect.contains(logical) ? ink : (border && outerRect.contains(logical) ? borderColor : background);
                expected.setPixelColor(x, y, wanted);
                if (actual.pixelColor(x, y) != wanted) ++mismatched;
                if (actual.pixelColor(x, y) == borderColor) ++borderPixels;
                if (actual.pixelColor(x, y) == ink) ++contentPixels;
            }
            const QString stem = QStringLiteral(".tmp/ui-screenshots/desktop-inline-border-%1-%2-dpr%3").arg(vectorPayload ? "svg" : "png").arg(borderMode).arg(dpr);
            QVERIFY(actual.save(stem + "-actual.png")); QVERIFY(expected.save(stem + "-reference.png"));
            qInfo() << "INLINE_BORDER" << vectorPayload << borderMode << dpr << "mismatched" << mismatched << "content" << contentPixels << "border" << borderPixels;
            QCOMPARE(contentPixels, qsizetype(40 * 20 * dpr * dpr));
            QCOMPARE(borderPixels, qsizetype(border ? (42 * 22 - 40 * 20) * dpr * dpr : 0));
            QCOMPARE(mismatched, qsizetype(0));
        }
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-inline-border-%1-%2-window.png").arg(vectorPayload ? "svg" : "png").arg(borderMode)));
        if (border) {
            QJsonObject missing = entry; missing.insert("media", QJsonArray{}); render(missing);
            QTRY_COMPARE(images().first().second.intProperty(SemanticHtml::inlineImageStateProperty), int(MediaPanel::InlineImageState::Error));
            sample = images().first();
            QCOMPARE(sample.second.width(), 40.0); QCOMPARE(sample.second.height(), 40.0);
            QCOMPARE(handler->intrinsicSize(document, sample.first, sample.second), QSizeF(42, 42));
            QVERIFY(sample.second.boolProperty(SemanticHtml::inlineImageBorderProperty));
            QVERIFY(window.reading_->accessibleDescription().contains(QStringLiteral("not in the dictionary's media catalogue")));
            QCOMPARE(window.currentEntry_, missing);
        }
    }

    void largeInlineSvgKeepsFineDetailAtDeviceResolution() {
        QSettings().setValue("media/allowImages", true);
        QSettings().setValue("media/cacheMb", 10);
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(1120, 800); window.show();
        const QString file = QStringLiteral("Vector fidelity fixture.svg");
        const QString host = LibraryStorage::sourceHost(window.api_->root());
        const QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/media-v1");
        QVERIFY(QDir().mkpath(cache));
        const QString key = QString::fromLatin1(QCryptographicHash::hash((host + ":image:" + file).toUtf8(), QCryptographicHash::Sha256).toHex());
        const QString payloadPath = cache + '/' + key + ".bin", metadataPath = cache + '/' + key + ".json";
        const auto removeFixture = qScopeGuard([&] { QFile::remove(payloadPath); QFile::remove(metadataPath); });
        // Owned vector data. At600 logical pixels wide the bars are1 pixel wide,
        // beyond the detail retained by the current400px-wide shared bitmap.
        QByteArray svg = R"svg(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="40" viewBox="0 0 20 40"><rect width="20" height="40" fill="#ff00ff"/><rect x="1" y="1" width="18" height="38" fill="white"/>)svg";
        for (int stripe = 0; stripe < 480; stripe += 2)
            svg += "<rect x=\"" + QByteArray::number(2.0 + stripe / 30.0, 'f', 8)
                + "\" y=\"2\" width=\"0.03333333\" height=\"4\" fill=\"black\"/>";
        svg += R"svg(<path d="M2 8L18 20M2 20L18 8" fill="none" stroke="black" stroke-width="0.04"/><circle cx="10" cy="29" r="7" fill="none" stroke="black" stroke-width="0.04"/></svg>)svg";
        QFile payload(payloadPath); QVERIFY(payload.open(QIODevice::WriteOnly)); QCOMPARE(payload.write(svg), svg.size()); payload.close();
        const QJsonObject assetMetadata{{"url", "https://upload.wikimedia.org/wikipedia/commons/a/vector-fidelity-fixture.svg"},
            {"source", "https://commons.wikimedia.org/wiki/File:Vector_fidelity_fixture.svg"}, {"credit", "Owned fine-line SVG"},
            {"intrinsic_width", 20}, {"intrinsic_height", 40}, {"original_mime", "image/svg+xml"}};
        QFile metadata(metadataPath); QVERIFY(metadata.open(QIODevice::WriteOnly));
        const QByteArray metadataBytes = QJsonDocument(assetMetadata).toJson(QJsonDocument::Compact);
        QCOMPARE(metadata.write(metadataBytes), metadataBytes.size()); metadata.close();
        const QJsonObject image{{"file", file}, {"height_px", 1200}, {"alt", ""}, {"tooltip", QJsonValue::Null}};
        const QJsonObject span{{"kind", "text"}, {"text", ""}, {"target", ""}, {"image", image}};
        const QJsonObject paragraph{{"kind", "paragraph"}, {"spans", QJsonArray{span}}};
        const QJsonObject section{{"level", 2}, {"title", "Large vector detail"}, {"blocks", QJsonArray{paragraph}}};
        const QJsonObject entry{{"title", "Owned vector fidelity fixture"}, {"kind", "language"}, {"language", window.api_->language()},
            {"sections", QJsonArray{section}}, {"media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", file}, {"caption", "Owned fine-line SVG"}}}}};
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        const auto firstImage = [&] {
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it)
                    if (it.fragment().charFormat().isImageFormat()) return it.fragment().charFormat().toImageFormat();
            return QTextImageFormat();
        };
        QTRY_COMPARE_WITH_TIMEOUT(firstImage().intProperty(SemanticHtml::inlineImageStateProperty), int(MediaPanel::InlineImageState::Ready), 10000);
        const auto format = firstImage();
        QCOMPARE(format.width(), 600.0); QCOMPARE(format.height(), 1200.0);
        QVERIFY(format.hasProperty(QTextFormat::ImageAltText)); QCOMPARE(format.stringProperty(QTextFormat::ImageAltText), QString());
        QVERIFY(!format.isAnchor()); QVERIFY(format.anchorHref().isEmpty()); QCOMPARE(window.currentEntry_, entry);
        window.reading_->verticalScrollBar()->setValue(0); window.reading_->horizontalScrollBar()->setValue(0);
        QCoreApplication::processEvents();
        const qreal dpr = window.reading_->viewport()->devicePixelRatioF();
        const QSize target(qRound(format.width() * dpr), qRound(format.height() * dpr));
        // Independent native-resolution oracle, not a resized product resource.
        QBuffer original(&svg); QVERIFY(original.open(QIODevice::ReadOnly));
        QImageReader referenceReader(&original); referenceReader.setScaledSize(target);
        const QImage reference = referenceReader.read();
        QVERIFY2(!reference.isNull(), qPrintable(referenceReader.errorString())); QCOMPARE(reference.size(), target);
        const QImage actual = window.reading_->viewport()->grab().toImage();
        QCOMPARE(actual.devicePixelRatio(), dpr);
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        const QString stem = QStringLiteral(".tmp/ui-screenshots/desktop-vector-detail-dpr%1").arg(dpr, 0, 'g', 3);
        QVERIFY(window.grab().save(stem + QStringLiteral("-window.png")));
        QVERIFY(actual.save(stem + QStringLiteral("-actual.png")));
        QVERIFY(reference.save(stem + QStringLiteral("-reference.png")));
        // Magenta belongs only to this fixture's border. It locates the image
        // in the actual viewport without assuming themed furniture coordinates.
        int left = actual.width(), top = actual.height(), right = -1;
        for (int y = 0; y < actual.height(); ++y)
            for (int x = 0; x < actual.width(); ++x)
                if (actual.pixelColor(x, y) == QColor(255, 0, 255)) { left = qMin(left, x); top = qMin(top, y); right = qMax(right, x); }
        QVERIFY(right >= left); QVERIFY(top < actual.height());
        QVERIFY(qAbs(right - left + 1 - target.width()) <= 2);
        const QRect detail(qRound(target.width() * 0.125), qRound(target.height() * 0.075),
            qRound(target.width() * 0.5), qRound(target.height() * 0.025));
        QVERIFY(reference.rect().contains(detail));
        int darkest = 255, lightest = 0;
        for (int x = detail.left(); x <= detail.right(); ++x) {
            const int value = qGray(reference.pixel(x, detail.center().y()));
            darkest = qMin(darkest, value); lightest = qMax(lightest, value);
        }
        QVERIFY(darkest <= 32 && lightest >= 223); // Oracle itself retains contrasting fine bars.
        double bestError = std::numeric_limits<double>::infinity();
        // Allow only the integer rounding of the located painted border, not
        // scaling or blurring of either image to manufacture agreement.
        for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) {
            const QPoint origin(left + dx, top + dy);
            if (!actual.rect().contains(detail.translated(origin))) continue;
            qint64 error = 0;
            for (int y = detail.top(); y <= detail.bottom(); ++y)
                for (int x = detail.left(); x <= detail.right(); ++x)
                    error += qAbs(qGray(actual.pixel(origin.x() + x, origin.y() + y)) - qGray(reference.pixel(x, y)));
            bestError = qMin(bestError, double(error) / (detail.width() * detail.height()));
        }
        const QImage resource = window.reading_->document()->resource(QTextDocument::ImageResource, QUrl(format.name())).value<QImage>();
        qInfo() << "SVG_DETAIL" << "dpr" << dpr << "target" << target << "resource" << resource.size() << "mean_gray_error" << bestError;
        QVERIFY2(bestError <= 8.0, qPrintable(QStringLiteral("Normal reader lost SVG fine detail: mean gray error%1 at DPR%2 (allowed8/255)").arg(bestError).arg(dpr)));
    }

    void compiledContentWalksFinalScopesAndCaptionsOnce() {
        const auto span = [](const QString &text) { return QJsonObject{{"kind", "text"}, {"text", text}}; };
        const auto paragraph = [](const QJsonArray &spans) {
            return QJsonObject{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", spans}};
        };
        const auto inlinePart = [](const QJsonArray &spans) { return QJsonObject{{"kind", "inline"}, {"spans", spans}}; };
        const auto scopePart = [](const QJsonArray &parts, const QString &direction = QStringLiteral("ltr")) {
            return QJsonObject{{"kind", "scope"}, {"spans", QJsonArray{}}, {"scope", QJsonObject{
                {"mode", "isolate"}, {"authored_direction", QJsonValue::Null},
                {"resolved_direction", direction}, {"language", ""}, {"parts", parts}}}};
        };
        const auto image = span(QStringLiteral("image"));
        const QJsonObject captionParagraph = paragraph(QJsonArray{span(QStringLiteral("caption"))});
        const QJsonObject figure{{"image_span", image}, {"caption", QJsonArray{}},
            {"caption_blocks", QJsonArray{captionParagraph}}};
        const QJsonObject nestedScope = scopePart(QJsonArray{inlinePart(QJsonArray{span(QStringLiteral("nested"))})}, QStringLiteral("rtl"));
        const QJsonObject mixedScope = scopePart(QJsonArray{inlinePart(QJsonArray{span(QStringLiteral("before"))}),
            QJsonObject{{"kind", "figure"}, {"spans", QJsonArray{}}, {"figure", figure}}, nestedScope,
            inlinePart(QJsonArray{span(QStringLiteral("after"))})});
        QJsonObject mixed = paragraph({}); mixed.insert("flow", QJsonArray{mixedScope});
        const QJsonObject table{{"caption", QJsonArray{}}, {"caption_blocks", QJsonArray{paragraph(QJsonArray{span("table-caption")})}},
            {"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{
                QJsonObject{{"spans", QJsonArray{}}, {"blocks", QJsonArray{mixed}}},
                QJsonObject{{"spans", QJsonArray{span("last-cell")}}}}}}}}};
        const QJsonObject tableBlock{{"kind", "table"}, {"spans", QJsonArray{}}, {"table", table}};
        const QJsonObject entry{{"display_title", QJsonArray{span("title")}}, {"preamble_spans", QJsonArray{span("preamble")}},
            {"sections", QJsonArray{QJsonObject{{"blocks", QJsonArray{tableBlock}}}}},
            {"references", QJsonArray{QJsonObject{{"spans", QJsonArray{}},
                {"blocks", QJsonArray{paragraph(QJsonArray{span("reference")})}}}}}};
        const QByteArray unchanged = QJsonDocument(entry).toJson(QJsonDocument::Compact);
        QStringList observed;
        const auto collect = [&](const QJsonArray &spans, const CompiledContent::Context &) {
            for (const QJsonValue &value : spans) observed.append(value.toObject().value("text").toString());
        };
        CompiledContent::Walker walker(collect, CompiledContent::TableSpans::Stored);
        walker.entry(entry);
        QCOMPARE(observed, QStringList({"title", "preamble", "table-caption", "before", "image",
            "caption", "nested", "after", "last-cell", "reference"}));
        QCOMPARE(QJsonDocument(entry).toJson(QJsonDocument::Compact), unchanged);
        QJsonObject legacyTable = tableBlock;
        legacyTable.insert("spans", QJsonArray{span("legacy-owner-spans")});
        observed.clear(); walker.block(legacyTable);
        QCOMPARE(observed.first(), QStringLiteral("legacy-owner-spans"));
        CompiledContent::Walker visibleBody(collect, CompiledContent::TableSpans::VisibleBody);
        observed.clear(); visibleBody.block(legacyTable);
        QCOMPARE(observed.first(), QStringLiteral("table-caption"));
        QVERIFY(!observed.contains(QStringLiteral("legacy-owner-spans")));
        QCOMPARE(legacyTable.value("spans").toArray(), QJsonArray{span("legacy-owner-spans")});
        const QJsonObject checkedScope = CompiledContent::scope(mixedScope.value("scope"));
        QVERIFY(checkedScope.value("language").isString());
        QVERIFY(checkedScope.value("language").toString().isEmpty());
        QJsonObject inheritedScope = checkedScope; inheritedScope.insert("language", QJsonValue::Null);
        QVERIFY(CompiledContent::scope(inheritedScope).value("language").isNull());
        QCOMPARE(CompiledContent::scope(nestedScope.value("scope")).value("resolved_direction").toString(), QStringLiteral("rtl"));

        // Explicit empty owners do not fall back to an inactive span array.
        QJsonObject emptyFigure = figure; emptyFigure.insert("caption_blocks", QJsonArray{});
        observed.clear(); walker.figure(emptyFigure, {}); QCOMPARE(observed, QStringList({"image"}));
        QJsonObject mixedCaption = emptyFigure; mixedCaption.insert("caption", QJsonArray{span("duplicate")});
        QVERIFY_EXCEPTION_THROWN(walker.figure(mixedCaption, {}), std::runtime_error);
        QJsonObject mixedFlow = mixed; mixedFlow.insert("spans", QJsonArray{span("duplicate")});
        QVERIFY_EXCEPTION_THROWN(walker.block(mixedFlow), std::runtime_error);
        QJsonObject mixedFigure = mixed; mixedFigure.insert("figure", figure);
        QVERIFY_EXCEPTION_THROWN(walker.block(mixedFigure), std::runtime_error);
        QJsonObject invalidScope = checkedScope; invalidScope.insert("authored_direction", "rtl");
        QVERIFY_EXCEPTION_THROWN(CompiledContent::scope(invalidScope), std::runtime_error);
        invalidScope = checkedScope; invalidScope.insert("mode", "isolate_override");
        invalidScope.insert("authored_direction", "auto");
        QVERIFY_EXCEPTION_THROWN(CompiledContent::scope(invalidScope), std::runtime_error);
        invalidScope = checkedScope; invalidScope.remove("language");
        QVERIFY_EXCEPTION_THROWN(CompiledContent::scope(invalidScope), std::runtime_error);
        const QJsonArray unknownPart{QJsonObject{{"kind", "unknown"}, {"spans", QJsonArray{}}}};
        QVERIFY_EXCEPTION_THROWN(walker.parts(unknownPart, {}), std::runtime_error);
        const QJsonArray missingPartSpans{QJsonObject{{"kind", "inline"}}};
        QVERIFY_EXCEPTION_THROWN(walker.parts(missingPartSpans, {}), std::runtime_error);

        // The limits share one content budget across flow, scope and captions;
        // tables have their separate inherited table-depth budget.
        QJsonArray chain{inlinePart(QJsonArray{span("limit")})};
        for (int index = 0; index != 15; ++index) chain = QJsonArray{scopePart(chain)};
        QJsonObject atLimit = paragraph({}); atLimit.insert("flow", chain);
        observed.clear(); walker.block(atLimit); QCOMPARE(observed, QStringList({"limit"}));
        atLimit.insert("flow", QJsonArray{scopePart(chain)});
        QVERIFY_EXCEPTION_THROWN(walker.block(atLimit), std::runtime_error);
        QJsonObject overflowCaption = figure; overflowCaption.insert("caption_blocks", QJsonArray{mixed});
        QVERIFY_EXCEPTION_THROWN(walker.figure(overflowCaption, {15, 0}), std::runtime_error);
        QJsonObject nestedTable{{"caption", QJsonArray{}}, {"rows", QJsonArray{QJsonObject{{"cells",
            QJsonArray{QJsonObject{{"spans", QJsonArray{span("table-limit")}}}}}}}}};
        for (int index = 1; index != 16; ++index)
            nestedTable = QJsonObject{{"caption", QJsonArray{}}, {"rows", QJsonArray{QJsonObject{{"cells",
                QJsonArray{QJsonObject{{"spans", QJsonArray{}}, {"nested_table", nestedTable}}}}}}}};
        QJsonObject tableAtLimit{{"kind", "table"}, {"spans", QJsonArray{}}, {"table", nestedTable}};
        observed.clear(); walker.block(tableAtLimit); QCOMPARE(observed, QStringList({"table-limit"}));
        nestedTable = QJsonObject{{"caption", QJsonArray{}}, {"rows", QJsonArray{QJsonObject{{"cells",
            QJsonArray{QJsonObject{{"spans", QJsonArray{}}, {"nested_table", nestedTable}}}}}}}};
        tableAtLimit.insert("table", nestedTable);
        QVERIFY_EXCEPTION_THROWN(walker.block(tableAtLimit), std::runtime_error);
    }

    void mediaCatalogueOmitsOnlyNormalizedFilenameCaptions() {
        MainWindow window{QString()};
        const QString file = QStringLiteral("Flag of Ukraine.svg");
        const QString url = QStringLiteral("https://commons.wikimedia.org/wiki/File:Flag%20of%20Ukraine.svg");
        const auto entryFor = [](const QString &name, const QString &caption) {
            return QJsonObject{{QStringLiteral("sections"), QJsonArray{}},
                {QStringLiteral("media"), QJsonArray{QJsonObject{
                    {QStringLiteral("kind"), QStringLiteral("image")},
                    {QStringLiteral("file"), name}, {QStringLiteral("caption"), caption}}}}};
        };
        for (const QString &caption : {file, QStringLiteral("Flag_of_Ukraine.svg"),
                                      QStringLiteral("  Flag of\tUkraine.svg  "), QString()}) {
            const QJsonObject entry = entryFor(file, caption), original = entry;
            QTextDocument document;
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(document.toPlainText().count(file), 1);
            const QTextCursor label = document.find(file);
            QVERIFY(!label.isNull());
            QCOMPARE(label.block().text(), QStringLiteral("image: ") + file);
            QCOMPARE(label.charFormat().anchorHref(), url);
            QCOMPARE(entry, original);
        }
        for (const QString &caption : {QStringLiteral("Distinct authored flag caption"),
                                      QStringLiteral("flag of Ukraine.svg"),
                                      QStringLiteral("<b>Flag of Ukraine.svg</b> & context")}) {
            const QJsonObject entry = entryFor(file, caption), original = entry;
            QTextDocument document;
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(document.find(file).block().text(), QStringLiteral("image: ") + file +
                QStringLiteral(" ") + QChar(0x00b7) + QStringLiteral(" ") + caption);
            QCOMPARE(document.find(file).charFormat().anchorHref(), url);
            QCOMPARE(entry, original);
        }
        const QString underscored = QStringLiteral("Flag_of_Ukraine.svg");
        QTextDocument document;
        document.setHtml(window.entryHtml(entryFor(underscored, file)));
        QCOMPARE(document.toPlainText().count(underscored), 1);
        QVERIFY(!document.toPlainText().contains(file));
        QCOMPARE(document.find(underscored).charFormat().anchorHref(),
                 QStringLiteral("https://commons.wikimedia.org/wiki/File:Flag_of_Ukraine.svg"));
    }

    void compiledScopeLanguagesInheritResetAndRestore() {
        const auto span = [](const QString &text, const QString &language = {}) {
            return QJsonObject{{"kind", "text"}, {"text", text}, {"language", language}};
        };
        const auto inlinePart = [](const QJsonArray &spans) {
            return QJsonObject{{"kind", "inline"}, {"spans", spans}};
        };
        const auto scopePart = [](const QJsonValue &language, const QJsonArray &parts) {
            return QJsonObject{{"kind", "scope"}, {"spans", QJsonArray{}}, {"scope", QJsonObject{
                {"mode", "isolate"}, {"authored_direction", QJsonValue::Null},
                {"resolved_direction", "ltr"}, {"language", language}, {"parts", parts}}}};
        };
        const auto paragraph = [](const QJsonArray &spans) {
            return QJsonObject{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", spans}};
        };
        const QJsonObject figure{{"image_span", span("image")}, {"caption", QJsonArray{}},
            {"caption_blocks", QJsonArray{paragraph(QJsonArray{span("caption")})}}};
        const QJsonArray flow{
            inlinePart(QJsonArray{span("root")}),
            scopePart(QJsonValue::Null, QJsonArray{inlinePart(QJsonArray{span("inherit")})}),
            scopePart(QString{}, QJsonArray{
                inlinePart(QJsonArray{span("reset"), span("span-override", "en")}),
                scopePart(QJsonValue::Null, QJsonArray{inlinePart(QJsonArray{span("inherit-reset")})}),
                scopePart("fr", QJsonArray{inlinePart(QJsonArray{span("replace")}),
                    QJsonObject{{"kind", "figure"}, {"spans", QJsonArray{}}, {"figure", figure}}}),
                inlinePart(QJsonArray{span("after-nested")})}),
            inlinePart(QJsonArray{span("after-scope")})};
        QJsonObject owner = paragraph({}); owner.insert("flow", flow);
        QJsonObject entry{{"language", "en"}, {"sections", QJsonArray{
            QJsonObject{{"blocks", QJsonArray{owner}}}}}};
        const QByteArray before = QJsonDocument(entry).toJson(QJsonDocument::Compact);
        QStringList observed;
        const auto collect = [&](const QJsonArray &spans, const CompiledContent::Context &context) {
            for (const QJsonValue &value : spans) {
                const QJsonObject item = value.toObject();
                observed.append(item.value("text").toString() + QChar(':')
                    + CompiledContent::languageForSpan(item, context));
            }
        };
        CompiledContent::Walker walker(collect, CompiledContent::TableSpans::Stored);
        walker.entry(entry);
        QCOMPARE(observed, QStringList({"root:en", "inherit:en", "reset:", "span-override:en",
            "inherit-reset:", "replace:fr", "image:fr", "caption:fr", "after-nested:", "after-scope:en"}));
        QCOMPARE(QJsonDocument(entry).toJson(QJsonDocument::Compact), before);
        entry.insert("language_code", "de");
        observed.clear(); walker.entry(entry);
        QCOMPARE(observed.first(), QStringLiteral("root:de"));
        QCOMPARE(observed.at(1), QStringLiteral("inherit:de"));
        QCOMPARE(observed.at(2), QStringLiteral("reset:"));
        QCOMPARE(observed.last(), QStringLiteral("after-scope:de"));
        observed.clear();
        walker.block(paragraph(QJsonArray{span("new-call")}), {}, {QStringLiteral("de")});
        QCOMPARE(observed, QStringList({"new-call:de"}));
    }

    void logicalOwnerAccessibilityKeepsOriginalCaptionRangesAndGeometry() {
        // Controlled document projection through the real reader adapter. This
        // requires paired private Gui/Widgets; it is not compiled-J interoperability.
        MainWindow window{QString()};
        window.resize(900, 640); window.show();
        auto *browser = window.reading_;
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        QTRY_VERIFY(browser->isVisible());
        window.activateWindow(); browser->setFocus(Qt::OtherFocusReason);
        QTRY_VERIFY(browser->hasFocus());
        auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible);
        QCOMPARE(accessible->role(), QAccessible::StaticText);
        auto *text = accessible->textInterface(); QVERIFY(text);
        const auto textPart = [](int first, int last) {
            return QVariantMap{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("first"), first}, {QStringLiteral("last"), last}};
        };
        bool sawDiscontiguousLine = false;
        for (Qt::LayoutDirection direction : {Qt::LeftToRight, Qt::RightToLeft}) {
            for (auto placement : {QTextFrameFormat::FloatLeft, QTextFrameFormat::FloatRight}) {
                browser->setLayoutDirection(direction);
                browser->clear();
                auto *document = browser->document();
                auto *layout = document->documentLayout();
                QCOMPARE(layout->property("_wikidictLogicalFlowCapability").toString(),
                         QStringLiteral("wikidict.logical-flow/1"));
                const auto registerOwners = [&](const QVariantList &owners) {
                    bool accepted = false;
                    return QMetaObject::invokeMethod(layout, "wikidictSetLogicalFlows", Qt::DirectConnection,
                        Q_RETURN_ARG(bool, accepted), Q_ARG(QVariantList, owners)) && accepted;
                };
                QVERIFY(registerOwners({}));
                QTextCursor cursor(document);
                cursor.insertText(QStringLiteral("Ordinary predecessor"));
                cursor.insertBlock(QTextBlockFormat{});
                const int first = cursor.position();
                cursor.insertText(QStringLiteral("Prefix A\u0301 before "));
                const int prefixEnd = cursor.position();
                QTextFrameFormat frameFormat;
                frameFormat.setWidth(126); frameFormat.setMargin(0);
                frameFormat.setPadding(4); frameFormat.setBorder(1);
                frameFormat.setPosition(placement);
                frameFormat.setProperty(QTextFormat::UserProperty + 0x57a0, QStringLiteral("wikidict.figure-layout/1"));
                frameFormat.setProperty(QTextFormat::UserProperty + 0x57a1, 0);
                frameFormat.setProperty(QTextFormat::UserProperty + 0x57a2,
                    placement == QTextFrameFormat::FloatLeft ? 2 : 3);
                auto *figure = cursor.insertFrame(frameFormat);
                auto caption = figure->firstCursorPosition();
                caption.setBlockFormat(QTextBlockFormat{});
                const int captionFirst = caption.position();
                QTextCharFormat link;
                link.setAnchor(true); link.setAnchorHref(QStringLiteral("dict:caption"));
                link.setFontWeight(QFont::Bold);
                caption.insertText(QStringLiteral("Caption linked text"), link);
                caption.insertBlock(QTextBlockFormat{}, QTextCharFormat{});
                caption.insertText(QStringLiteral("Second caption line"));
                cursor.setPosition(figure->lastPosition() + 1);
                const int suffixFirst = cursor.position();
                cursor.insertText(QStringLiteral(" suffix \u05d0\u05d1\u05d2 words continued after the actual caption frame"));
                const int last = cursor.position();
                cursor.insertBlock(QTextBlockFormat{}, QTextCharFormat{});
                cursor.insertText(QStringLiteral("Ordinary successor"));
                const QVariantMap owner{{QStringLiteral("first"), first}, {QStringLiteral("last"), last},
                    {QStringLiteral("direction"), int(direction)}, {QStringLiteral("joins"), QVariantList{}},
                    {QStringLiteral("parts"), QVariantList{textPart(first, prefixEnd),
                        QVariantMap{{QStringLiteral("kind"), QStringLiteral("frame")},
                                    {QStringLiteral("object"), figure->objectIndex()}}, textPart(suffixFirst, last)}}};
                QTextCursor all(document); all.select(QTextCursor::Document);
                const QString sourceSelection = all.selectedText();
                const QString sourcePlainText = document->toPlainText();
                const int sourceCount = document->characterCount();
                const auto originalFrame = figure->frameFormat();
                QVERIFY(registerOwners({owner}));
                bool hasOwners = false;
                QVERIFY(QMetaObject::invokeMethod(layout, "wikidictHasLogicalFlows", Qt::DirectConnection,
                    Q_RETURN_ARG(bool, hasOwners)));
                QVERIFY(hasOwners);
                int resizeIteration = 0;
                for (int width : {900, 640, 900}) {
                    ++resizeIteration;
                    window.resize(width, 640);
                    QTRY_COMPARE(window.width(), width);
                    QTRY_VERIFY(browser->isVisible() && browser->viewport()->isVisible());
                    QTRY_VERIFY(browser->hasFocus());
                    QCoreApplication::processEvents();
                    document->size();
                    QCOMPARE(document->characterCount(), sourceCount);
                    QCOMPARE(document->toPlainText(), sourcePlainText);
                    all.select(QTextCursor::Document);
                    QCOMPARE(all.selectedText(), sourceSelection);
                    QCOMPARE(figure->frameFormat(), originalFrame);
                    QCOMPARE(text->characterCount(), sourceCount - 1);
                    QCOMPARE(text->text(0, -1), QString(sourceSelection).replace(QChar::ParagraphSeparator, QChar('\n')));
                    QVariantMap prefixGeometry, suffixGeometry;
                    QVERIFY(QMetaObject::invokeMethod(layout, "wikidictLogicalPosition", Qt::DirectConnection,
                        Q_RETURN_ARG(QVariantMap, prefixGeometry), Q_ARG(int, first + 2)));
                    QVERIFY(QMetaObject::invokeMethod(layout, "wikidictLogicalPosition", Qt::DirectConnection,
                        Q_RETURN_ARG(QVariantMap, suffixGeometry), Q_ARG(int, suffixFirst + 2)));
                    QVERIFY(prefixGeometry.value(QStringLiteral("handled")).toBool());
                    QVERIFY(suffixGeometry.value(QStringLiteral("handled")).toBool());
                    QCOMPARE(prefixGeometry.value(QStringLiteral("error")).toInt(), 0);
                    QCOMPARE(suffixGeometry.value(QStringLiteral("error")).toInt(), 0);
                    sawDiscontiguousLine |= prefixGeometry.value(QStringLiteral("lineNumber"))
                        == suffixGeometry.value(QStringLiteral("lineNumber"));
                    for (auto boundary : {QAccessible::LineBoundary, QAccessible::ParagraphBoundary}) {
                        int start = -1, end = -1;
                        const auto prefix = text->textAtOffset(first + 2, boundary, &start, &end);
                        QVERIFY(start <= first + 2 && end > first + 2);
                        QVERIFY(end <= figure->firstPosition());
                        QVERIFY(!prefix.contains(QStringLiteral("Caption")));
                        QCOMPARE(prefix, text->text(start, end));
                        const auto captionText = text->textAtOffset(captionFirst + 2, boundary, &start, &end);
                        QVERIFY(start >= figure->firstPosition() && end <= figure->lastPosition());
                        QVERIFY(start <= captionFirst + 2 && end > captionFirst + 2);
                        QVERIFY(captionText.contains(QStringLiteral("Caption")));
                        const auto suffix = text->textAtOffset(suffixFirst + 2, boundary, &start, &end);
                        QVERIFY(start >= suffixFirst && end > suffixFirst + 2);
                        QCOMPARE(suffix, text->text(start, end));
                        for (bool backwards : {false, true}) {
                            QVector<int> visits(last - first, 0);
                            bool captionVisited = false, prefixVisited = false, suffixVisited = false;
                            int previous = backwards ? sourceCount : -1;
                            start = backwards ? last + 1 : first;
                            if (!backwards) text->textAtOffset(start, boundary, &start, &end);
                            for (int step = 0; step < sourceCount; ++step) {
                                QString rangeText;
                                if (backwards) rangeText = text->textBeforeOffset(start, boundary, &start, &end);
                                else rangeText = text->text(start, end);
                                if (start < 0 || start >= last) break;
                                QVERIFY(backwards ? start < previous : start > previous);
                                QVERIFY(end >= start && end <= sourceCount - 1);
                                QCOMPARE(rangeText, text->text(start, end));
                                previous = start;
                                captionVisited |= start >= figure->firstPosition() && start <= captionFirst;
                                prefixVisited |= start <= first;
                                suffixVisited |= start >= suffixFirst;
                                for (int pos = qMax(start, first); pos < qMin(end, last); ++pos)
                                    ++visits[pos - first];
                                if (backwards && start <= first) break;
                                if (!backwards) text->textAfterOffset(start, boundary, &start, &end);
                            }
                            QVERIFY(captionVisited); QVERIFY(prefixVisited); QVERIFY(suffixVisited);
                            for (int pos = first; pos < last; ++pos) {
                                const ushort ch = document->characterAt(pos).unicode();
                                if (ch == QChar::ParagraphSeparator || ch == 0xfdd0 || ch == 0xfdd1) continue;
                                QCOMPARE(visits[pos - first], 1);
                            }
                        }
                    }
                    for (int offset : {first + 2, suffixFirst + 2}) {
                        QTextCursor visible(document); visible.setPosition(offset);
                        browser->setTextCursor(visible); browser->ensureCursorVisible();
                        QVariantMap geometry;
                        QVERIFY(QMetaObject::invokeMethod(layout, "wikidictLogicalPosition", Qt::DirectConnection,
                            Q_RETURN_ARG(QVariantMap, geometry), Q_ARG(int, offset)));
                        QRectF expected = geometry.value(QStringLiteral("characterRect"),
                            geometry.value(QStringLiteral("cursorRect"))).toRectF();
                        expected.setWidth(qMax(qreal(1), expected.width()));
                        const int horizontal = browser->isRightToLeft()
                            ? browser->horizontalScrollBar()->maximum() - browser->horizontalScrollBar()->value()
                            : browser->horizontalScrollBar()->value();
                        expected.translate(browser->viewport()->mapToGlobal(QPoint())
                            - QPoint(horizontal, browser->verticalScrollBar()->value()));
                        QCOMPARE(text->characterRect(offset), expected.toAlignedRect());
                        QVERIFY(text->characterRect(offset).intersects(QRect(browser->viewport()->mapToGlobal(
                            browser->cursorRect(visible).topLeft()), browser->cursorRect(visible).size())));
                        // Retain scalars before the strict comparison returns from QTest.
                        // The original AX round trip is evaluated before the diagnostic
                        // direct hit, so that extra layout access cannot change its result.
                        const auto rectScalars = [](const QRectF &rect) {
                            return QJsonObject{{QStringLiteral("x"), rect.x()},
                                {QStringLiteral("y"), rect.y()},
                                {QStringLiteral("width"), rect.width()},
                                {QStringLiteral("height"), rect.height()},
                                {QStringLiteral("finite"), qIsFinite(rect.x()) && qIsFinite(rect.y())
                                    && qIsFinite(rect.width()) && qIsFinite(rect.height())}};
                        };
                        const QPoint viewportOrigin = browser->viewport()->mapToGlobal(QPoint());
                        const int vertical = browser->verticalScrollBar()->value();
                        const QRect axisRect = text->characterRect(offset);
                        const QPoint screenCenter = axisRect.center();
                        const QPoint documentCenter = browser->viewport()->mapFromGlobal(screenCenter)
                            + QPoint(horizontal, vertical);
                        const QRectF frameBefore = layout->frameBoundingRect(figure);
                        const int axisHit = text->offsetAtPoint(screenCenter);
                        const int directHit = layout->hitTest(documentCenter, Qt::ExactHit);
                        QJsonObject query = QJsonObject::fromVariantMap(geometry);
                        query.insert(QStringLiteral("characterRect"),
                            rectScalars(geometry.value(QStringLiteral("characterRect")).toRectF()));
                        query.insert(QStringLiteral("cursorRect"),
                            rectScalars(geometry.value(QStringLiteral("cursorRect")).toRectF()));
                        qInfo().noquote() << "LOGICAL_AX_HIT_DIAGNOSTIC" << QJsonDocument(QJsonObject{
                            {QStringLiteral("direction"), int(direction)},
                            {QStringLiteral("placement"), int(placement)},
                            {QStringLiteral("width"), width},
                            {QStringLiteral("resizeIteration"), resizeIteration},
                            {QStringLiteral("offset"), offset},
                            {QStringLiteral("sourceCharacter"), QString(document->characterAt(offset))},
                            {QStringLiteral("sourceCodeUnit"), int(document->characterAt(offset).unicode())},
                            {QStringLiteral("first"), first},
                            {QStringLiteral("captionFirst"), captionFirst},
                            {QStringLiteral("suffixFirst"), suffixFirst},
                            {QStringLiteral("nativeQuery"), query},
                            {QStringLiteral("axisScreenRect"), rectScalars(axisRect)},
                            {QStringLiteral("screenCenter"), QJsonArray{screenCenter.x(), screenCenter.y()}},
                            {QStringLiteral("documentCenter"), QJsonArray{documentCenter.x(), documentCenter.y()}},
                            {QStringLiteral("viewportOrigin"), QJsonArray{viewportOrigin.x(), viewportOrigin.y()}},
                            {QStringLiteral("horizontalOffset"), horizontal},
                            {QStringLiteral("verticalOffset"), vertical},
                            {QStringLiteral("captionFrameBefore"), rectScalars(frameBefore)},
                            {QStringLiteral("captionFrameAfter"), rectScalars(layout->frameBoundingRect(figure))},
                            {QStringLiteral("directHit"), directHit},
                            {QStringLiteral("axisHit"), axisHit}}).toJson(QJsonDocument::Compact);
                        QCOMPARE(axisHit, offset);
                    }
                    text->setSelection(0, captionFirst, captionFirst + 7);
                    QCOMPARE(browser->textCursor().selectedText(), QStringLiteral("Caption"));
                    int selectedFirst = -1, selectedLast = -1;
                    text->selection(0, &selectedFirst, &selectedLast);
                    QCOMPARE(selectedFirst, captionFirst); QCOMPARE(selectedLast, captionFirst + 7);
                    text->removeSelection(0);
                }
                // An edit invalidates the original-offset inventory. The adapter
                // must expose refusal, not fall back to unrelated physical lines.
                QTextCursor edit(document); edit.setPosition(first); edit.insertText(QStringLiteral("X"));
                int start = 123, end = 123;
                QCOMPARE(text->textAtOffset(first + 2, QAccessible::LineBoundary, &start, &end), QString());
                QCOMPARE(start, -1); QCOMPARE(end, -1);
                QVERIFY(text->characterRect(first + 2).isEmpty());
                QVERIFY(registerOwners({}));
                const auto stock = text->textAtOffset(first + 2, QAccessible::ParagraphBoundary, &start, &end);
                QVERIFY(start <= first + 2 && end > first + 2);
                QVERIFY(stock.startsWith(QStringLiteral("XPrefix")));
            }
        }
        QVERIFY(sawDiscontiguousLine);
    }

    void sourceParagraphRunsPreservePoemGeometryAndEmptyLines() {
        MainWindow window{QString()};
        const QString marked = QStringLiteral("wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-rtl");
        const QJsonArray first{
            QJsonObject{{"kind", "link"}, {"text", "Linked poem line with enough words to wrap"},
                {"target", "cat"}, {"classes", marked}, {"font_scale", 1.5}},
            QJsonObject{{"kind", "line_break"}, {"text", ""}, {"classes", marked}},
            QJsonObject{{"kind", "line_break"}, {"text", ""}, {"classes", marked}},
            QJsonObject{{"kind", "text"}, {"text", "Last poem line\n"}, {"classes", marked}}};
        const QJsonArray second{QJsonObject{{"kind", "text"}, {"text", "Other run"},
            {"classes", "wikidict-poem wikidict-poem-indent-1 wikidict-poem-dir-ltr"}}};
        QTextDocument baseline, owned;
        baseline.setDefaultFont(QFont(QStringLiteral("DejaVu Sans"), 19));
        owned.setDefaultFont(baseline.defaultFont());
        const QString plain = window.spansHtml(first, 7, {}, {}, 19)
            + window.spansHtml(second, 7, {}, {}, 19);
        const QString associated = window.spansHtml(first, 7, {}, {}, 19, {}, 31)
            + window.spansHtml(second, 7, {}, {}, 19, {}, 32);
        SemanticHtml::setHtml(&baseline, plain);
        SemanticHtml::setHtml(&owned, associated);
        QCOMPARE(owned.toRawText(), baseline.toRawText());
        QCOMPARE(owned.toHtml(), baseline.toHtml());
        QCOMPARE(owned.characterCount(), baseline.characterCount());
        QCOMPARE(owned.blockCount(), baseline.blockCount());
        int empty = 0, count31 = 0, count32 = 0;
        for (auto a = owned.begin(), b = baseline.begin(); a.isValid(); a = a.next(), b = b.next()) {
            QVERIFY(b.isValid());
            QCOMPARE(a.userState(), -1);
            auto format = a.blockFormat();
            QVERIFY(format.hasProperty(SemanticHtml::sourceRunProperty));
            const int run = format.intProperty(SemanticHtml::sourceRunProperty);
            QVERIFY(run == 31 || run == 32);
            count31 += run == 31; count32 += run == 32;
            empty += a.length() == 1;
            format.clearProperty(SemanticHtml::sourceRunProperty);
            QCOMPARE(format, b.blockFormat());
            auto character = a.charFormat();
            character.clearProperty(SemanticHtml::sourceRunProperty);
            QCOMPARE(character, b.charFormat());
            QCOMPARE(a.text(), b.text());
            for (auto it = a.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (!fragment.isValid()) continue;
                auto actual = fragment.charFormat();
                actual.clearProperty(SemanticHtml::sourceRunProperty);
                const int relative = fragment.position() - a.position();
                QTextCursor control(&baseline); control.setPosition(b.position() + relative);
                control.setPosition(b.position() + relative + 1, QTextCursor::KeepAnchor);
                QCOMPARE(actual, control.charFormat());
            }
        }
        QCOMPARE(count31, 4); QCOMPARE(count32, 1); QCOMPARE(empty, 2);
        QDir().mkpath(QStringLiteral(".tmp/ui-screenshots"));
        int poemFrame = 0;
        for (int width : {360, 180, 360}) {
            baseline.setTextWidth(width); owned.setTextWidth(width);
            QCOMPARE(owned.documentLayout()->documentSize(), baseline.documentLayout()->documentSize());
            for (auto a = owned.begin(), b = baseline.begin(); a.isValid(); a = a.next(), b = b.next()) {
                QCOMPARE(owned.documentLayout()->blockBoundingRect(a), baseline.documentLayout()->blockBoundingRect(b));
                QCOMPARE(a.layout()->lineCount(), b.layout()->lineCount());
                for (int line = 0; line < a.layout()->lineCount(); ++line) {
                    QCOMPARE(a.layout()->lineAt(line).rect(), b.layout()->lineAt(line).rect());
                    QCOMPARE(a.layout()->lineAt(line).textStart(), b.layout()->lineAt(line).textStart());
                    QCOMPARE(a.layout()->lineAt(line).textLength(), b.layout()->lineAt(line).textLength());
                }
            }
            // Retain actual document paint at the same checked wide/narrow
            // widths; no substitute layout or widget geometry is introduced.
            for (QTextDocument *document : {&baseline, &owned}) {
                const QSizeF size = document->documentLayout()->documentSize();
                QVERIFY(qIsFinite(size.width()) && qIsFinite(size.height()) && size.width() > 0 && size.height() > 0);
                QImage pixels(QSize(qCeil(size.width()), qCeil(size.height())), QImage::Format_ARGB32_Premultiplied);
                pixels.fill(Qt::white);
                QPainter painter(&pixels);
                document->drawContents(&painter);
                painter.end();
                QVERIFY(pixels.save(QStringLiteral(".tmp/ui-screenshots/poem-source-run-%1-%2-%3-%4.png")
                    .arg(QCoreApplication::applicationPid()).arg(poemFrame).arg(width)
                    .arg(document == &owned ? QStringLiteral("owned") : QStringLiteral("baseline"))));
            }
            ++poemFrame;
        }
        const auto link = owned.find(QStringLiteral("Linked"));
        QVERIFY(!link.isNull()); QVERIFY(link.charFormat().isAnchor());
        QCOMPARE(link.charFormat().anchorHref(), baseline.find(QStringLiteral("Linked")).charFormat().anchorHref());
        QTextCursor selected(&owned); selected.select(QTextCursor::Document);
        QTextCursor control(&baseline); control.select(QTextCursor::Document);
        QCOMPARE(selected.selectedText(), control.selectedText());
        // Only a generated marker can authorize temporary state normalization.
        QHash<int, int> runs;
        const auto unowned = SemanticHtml::prepareParagraphRuns(QStringLiteral("<p style='-qt-user-state:42'>Unowned</p>"), runs);
        QVERIFY(runs.isEmpty());
        SemanticHtml::setHtml(&owned, unowned);
        QCOMPARE(owned.begin().userState(), 42);
        for (const QString &bad : {QStringLiteral("-1"), QStringLiteral("01"), QStringLiteral("2147483648"), QStringLiteral("x")}) {
            QHash<int, int> invalid;
            QVERIFY_EXCEPTION_THROWN(SemanticHtml::prepareParagraphRuns(SemanticHtml::paragraphRunOpen + bad
                + QStringLiteral("\" dir='ltr' style='margin:0'>X</p>"), invalid), std::runtime_error);
        }
        QHash<int, int> shadowed;
        QVERIFY_EXCEPTION_THROWN(SemanticHtml::prepareParagraphRuns(SemanticHtml::paragraphRunOpen
            + QStringLiteral("1\" dir='ltr' style='-qt-user-state:42'>X</p>"), shadowed), std::runtime_error);
    }

    void sourceParagraphNormalizationStopsAfterSynchronousReplacement() {
        const QString html = SemanticHtml::paragraphRunOpen + QStringLiteral("7\" dir='ltr' style='margin:0'>")
            + SemanticHtml::scaledText(QStringLiteral("Original"), 2, QStringLiteral("expansion"))
            + QStringLiteral("</p>");
        QHash<QString, SemanticHtml::ScaleInfo> replacementMarkers;
        const QString replacement = SemanticHtml::prepare(
            SemanticHtml::scaledText(QStringLiteral("Replaced"), 2, QStringLiteral("expansion")), replacementMarkers);
        for (int mode : {0, 1, 2}) {
            QTextDocument document, other;
            other.setPlainText(QStringLiteral("Different document"));
            auto *browser = new QTextBrowser;
            QPointer<QTextBrowser> browserGuard(browser);
            browser->setDocument(&document); // External lifetime survives browser deletion.
            bool fired = false;
            QObject::connect(&document, &QTextDocument::contentsChanged, &document, [&] {
                if (fired || !document.begin().blockFormat().hasProperty(SemanticHtml::sourceRunProperty)
                    || document.begin().userState() != -1) return;
                fired = true;
                if (mode == 0) document.setHtml(replacement);
                else if (mode == 1) browser->setDocument(&other);
                else delete browser;
            });
            SemanticHtml::setHtml(browser, html);
            QVERIFY(fired);
            if (mode == 0) {
                QCOMPARE(document.toPlainText(), QStringLiteral("Replaced"));
                const auto text = document.find(QStringLiteral("Replaced"));
                QVERIFY(!text.isNull());
                // An old normalization pass would strip this matching token.
                QVERIFY(text.charFormat().toolTip().startsWith(SemanticHtml::scalePrefix));
            } else if (mode == 1) {
                QVERIFY(browserGuard);
                QCOMPARE(browser->document(), &other);
                QCOMPARE(other.toPlainText(), QStringLiteral("Different document"));
            } else QVERIFY(!browserGuard);
            if (browserGuard) delete browser;
        }
        QTextDocument direct;
        QHash<int, int> runs;
        direct.setHtml(SemanticHtml::prepareParagraphRuns(html, runs));
        bool replaced = false;
        QObject::connect(&direct, &QTextDocument::contentsChanged, &direct, [&] {
            if (replaced) return;
            replaced = true;
            direct.setPlainText(QStringLiteral("Replaced")); // Same character count; revision differs.
        });
        QVERIFY(!SemanticHtml::normalizeParagraphRuns(&direct, runs));
        QVERIFY(replaced);
        QCOMPARE(direct.toPlainText(), QStringLiteral("Replaced"));
    }

    void rawFlowParagraphSeparatorsKeepTheirParsedSourceRun() {
        const QString first = QString(QChar::ParagraphSeparator) + QChar::ParagraphSeparator + QStringLiteral("AV body");
        const QString second = QString(QChar::ParagraphSeparator) + QStringLiteral("next") + QChar::ParagraphSeparator;
        const auto marked = [](const QString &text, int run) {
            return SemanticHtml::scaledText(text.toHtmlEscaped(), 1, {}, SemanticHtml::Basis::Context,
                0, false, false, false, 0, QJsonValue(), true, run);
        };
        FlowConstruction::Rendered rendered;
        rendered.html = marked(first, 1) + marked(second, 2);
        rendered.parts = QJsonArray{QJsonObject{{"kind", "inline"}, {"run", 1}},
            QJsonObject{{"kind", "scope"}, {"mode", "isolate"}, {"direction", "rtl"},
                {"language", ""}, {"parts", QJsonArray{QJsonObject{{"kind", "inline"}, {"run", 2}}}}}};
        const QJsonObject block{{"kind", "paragraph"}, {"spans", QJsonArray{}}, {"depth", 0}, {"list_path", ""}};
        const QString role = QStringLiteral("<p style='margin:0'>Prefix:%1</p>");
        for (const QString &shell : {role, QStringLiteral("<p>Before</p>") + role + QStringLiteral("<p>After</p>"),
                QStringLiteral("<table><tr><td>First</td><td>") + role + QStringLiteral("</td></tr></table>")}) {
            QTextDocument document, baseline;
            const QFont font(QStringLiteral("DejaVu Sans"), 12);
            document.setDefaultFont(font); baseline.setDefaultFont(font);
            QCOMPARE(document.documentLayout()->property("_wikidictSourceProvenanceCapability").toString(),
                QStringLiteral("wikidict.source-provenance/1"));
            document.setHtml(shell.arg(FlowConstruction::placeholder(block, rendered, {QStringLiteral("en"), {}})));
            baseline.setHtml(shell.arg((first + second).toHtmlEscaped()));
            const auto prefix = document.find(QStringLiteral("Prefix:")); QVERIFY(!prefix.isNull());
            const auto prefixFormat = prefix.charFormat();
            const auto owners = FlowConstruction::expand(&document); QCOMPARE(owners.size(), 1);
            const auto &owner = owners.first();
            QCOMPARE(owner.authoredBoundaries.size(), 4);
            const QVector<int> runs{1, 1, 2, 2};
            for (qsizetype at = 0; at < runs.size(); ++at) {
                const auto &boundary = owner.authoredBoundaries[at];
                QCOMPARE(boundary.sourceRun, runs[at]);
                QCOMPARE(document.characterAt(boundary.character.position()), QChar(QChar::ParagraphSeparator));
                QCOMPARE(boundary.character.blockFormat().intProperty(SemanticHtml::sourceBoundaryProperty), runs[at]);
            }
            QCOMPARE(owner.first.block().blockFormat().intProperty(SemanticHtml::sourceBoundaryProperty), 1);
            QVERIFY(!owner.first.block().blockFormat().hasProperty(SemanticHtml::sourceRunProperty));
            QCOMPARE(document.find(QStringLiteral("Prefix:")).charFormat(), prefixFormat);
            QCOMPARE(document.toRawText(), baseline.toRawText());
            QCOMPARE(document.blockCount(), baseline.blockCount());
            for (int width : {600, 300, 600}) {
                document.setTextWidth(width); baseline.setTextWidth(width);
                QCOMPARE(document.documentLayout()->documentSize(), baseline.documentLayout()->documentSize());
                auto actual = document.begin(), expected = baseline.begin();
                for (; actual.isValid() && expected.isValid(); actual = actual.next(), expected = expected.next())
                    QCOMPARE(document.documentLayout()->blockBoundingRect(actual), baseline.documentLayout()->blockBoundingRect(expected));
                QVERIFY(!actual.isValid() && !expected.isValid());
            }
            const auto source = FlowConstruction::ranges(owner);
            QVERIFY(source.structuralJoins.isEmpty());
            const QString raw = document.toRawText();
            QVERIFY(LogicalFlow::registerOwners(&document, QVariantList{FlowConstruction::descriptor(owner)}));
            const auto body = document.find(QStringLiteral("AV body")); QVERIFY(!body.isNull());
            for (int width : {600, 300, 600}) {
                document.setTextWidth(width);
                QVERIFY(document.documentLayout()->documentSize().isValid());
                const QVariant error = document.documentLayout()->property("_wikidictParagraphBoxLayoutError");
                QCOMPARE(error.metaType().id(), int(QMetaType::Int)); QCOMPARE(error.toInt(), 0);
                const auto position = LogicalFlow::position(&document, body.selectionStart());
                QCOMPARE(position.status, LogicalFlow::Status::Handled); QCOMPARE(position.error, 0);
            }
            QCOMPARE(document.toRawText(), raw);
            for (const auto &boundary : owner.authoredBoundaries)
                QCOMPARE(document.characterAt(boundary.character.position()), QChar(QChar::ParagraphSeparator));
        }
    }

    void wholeFlowConstructionRetainsPoemBreaksAndRealCaptionOffsets() {
        MainWindow window{QString()};
        const QJsonArray poem{
            QJsonObject{{"kind", "text"}, {"text", "Poem first"}, {"classes", "wikidict-poem wikidict-poem-indent-2"}},
            QJsonObject{{"kind", "line_break"}, {"text", ""}},
            QJsonObject{{"kind", "line_break"}, {"text", ""}},
            QJsonObject{{"kind", "text"}, {"text", "Poem last"}, {"classes", "wikidict-poem wikidict-poem-dir-rtl"}}};
        const QJsonArray suffix{QJsonObject{{"kind", "link"}, {"text", " suffix"}, {"target", "cat"}}};
        // Internal construction metadata; the normal figure adapter supplies the
        // same native frame association after its own typed figure validation.
        FlowConstruction::Rendered rendered;
        rendered.html = window.spansHtml(poem, 0, {}, {}, 12, {}, 1)
            + SemanticHtml::scaledText(QStringLiteral("<img src='wikidict-construction-test:figure'>"), 1, {},
                SemanticHtml::Basis::Context, 0, false, false, false, 0, QJsonValue(), true, 2)
            + window.spansHtml(suffix, 0, {}, {}, 12, {}, 3);
        const QJsonArray scoped{
            QJsonObject{{"kind", "inline"}, {"run", 1}},
            QJsonObject{{"kind", "figure"}, {"run", 2}},
            QJsonObject{{"kind", "inline"}, {"run", 3}}};
        rendered.parts = QJsonArray{QJsonObject{{"kind", "scope"}, {"mode", "isolate"},
            {"direction", "rtl"}, {"language", ""}, {"parts", scoped}}};
        const QJsonObject block{{"kind", "paragraph"}, {"spans", QJsonArray{}}, {"depth", 0}, {"list_path", ""}};
        const QString role = QStringLiteral("<p style='margin-left:13px;margin-right:7px;margin-top:9px;margin-bottom:11px'>Prefix %1</p>");
        QJsonArray floatGeometryObservations;
        bool allBodyAvoidsCaption = true;
        int shellIndex = 0;
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        for (const QString &shell : {role, QStringLiteral("<p>Before</p>") + role + QStringLiteral("<p>After</p>"),
            QStringLiteral("<table><tr><td>First cell</td><td>") + role + QStringLiteral("</td></tr></table>")}) {
        QTextDocument document;
        document.setDefaultFont(QFont(QStringLiteral("DejaVu Sans"), 12));
        document.setHtml(shell.arg(FlowConstruction::placeholder(block, rendered, {QStringLiteral("en"), {}})));
        const auto prefixBefore = document.find(QStringLiteral("Prefix")); QVERIFY(!prefixBefore.isNull());
        const auto roleBefore = prefixBefore.blockFormat();
        const auto prefixFormat = prefixBefore.charFormat();
        QTextDocument paragraphControl;
        paragraphControl.setDefaultFont(document.defaultFont());
        SemanticHtml::setHtml(&paragraphControl, window.spansHtml(poem, 0, {}, {}, 12, {}, 1));
        const auto firstSource = paragraphControl.begin().blockFormat();
        auto owners = FlowConstruction::expand(&document);
        QCOMPARE(owners.size(), 1);
        QVERIFY(owners.first().authoredBoundaries.size() >= 2);
        const auto prefixAfter = document.find(QStringLiteral("Prefix")); QVERIFY(!prefixAfter.isNull());
        QCOMPARE(prefixAfter.charFormat(), prefixFormat);
        QCOMPARE(prefixAfter.blockFormat().leftMargin(), roleBefore.leftMargin() + firstSource.leftMargin());
        QCOMPARE(prefixAfter.blockFormat().rightMargin(), roleBefore.rightMargin() + firstSource.rightMargin());
        QCOMPARE(prefixAfter.blockFormat().topMargin(), roleBefore.topMargin());
        QCOMPARE(prefixAfter.blockFormat().bottomMargin(), roleBefore.bottomMargin());
        QCOMPARE(prefixAfter.blockFormat().layoutDirection(), firstSource.layoutDirection());
        QCOMPARE(prefixAfter.blockFormat().intProperty(SemanticHtml::sourceRunProperty), 1);
        int position = -1;
        for (auto b = document.begin(); b.isValid(); b = b.next())
            for (auto it = b.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (fragment.isValid() && fragment.charFormat().isImageFormat()
                    && fragment.charFormat().toImageFormat().name() == QStringLiteral("wikidict-construction-test:figure"))
                    position = fragment.position();
            }
        QVERIFY(position >= 0);
        QTextCursor insertion(&document); insertion.setPosition(position);
        insertion.setPosition(position + 1, QTextCursor::KeepAnchor);
        QTextFrameFormat format; format.setWidth(160); format.setPosition(QTextFrameFormat::FloatRight);
        format.setProperty(SemanticHtml::sourceRunProperty, 2);
        const auto caption = FlowConstruction::insertFigure(owners.first(), insertion, 2, format, [](QTextFrame *frame) {
            QTextCursor captionText = frame->firstCursorPosition();
            QTextCharFormat linked; linked.setAnchor(true); linked.setAnchorHref(QStringLiteral("wikidict:cat"));
            captionText.insertText(QStringLiteral("Real caption link"), linked);
        });
        QVERIFY(caption);
        QVERIFY(owners.first().figureJoins.isEmpty()); // Native frame boundaries are FDD0/FDD1, not new U+2029.
        const auto descriptor = FlowConstruction::descriptor(owners.first());
        const QString raw = document.toRawText();
        const int count = document.characterCount();
        const auto captionFormat = caption->frameFormat();
        auto *parent = caption->parentFrame();
        const auto nativeParts = descriptor.value(QStringLiteral("parts")).toList();
        QCOMPARE(nativeParts.size(), 2); // Prefix plus the one original compiled scope.
        const auto scopedParts = nativeParts.last().toMap().value(QStringLiteral("parts")).toList();
        int previousEnd = owners.first().prefixEnd.position();
        QVector<int> projectedBreaks;
        for (const auto &value : scopedParts) {
            const auto part = value.toMap();
            const QString kind = part.value(QStringLiteral("kind")).toString();
            int begin = -1, end = -1;
            if (kind == QStringLiteral("text")) {
                begin = part.value(QStringLiteral("first")).toInt(); end = part.value(QStringLiteral("last")).toInt();
            } else if (kind == QStringLiteral("frame")) {
                QCOMPARE(part.value(QStringLiteral("object")).toInt(), caption->objectIndex());
                begin = caption->firstPosition() - 1; end = caption->lastPosition() + 1;
            } else {
                QCOMPARE(kind, QStringLiteral("paragraph_break"));
                begin = part.value(QStringLiteral("position")).toInt(); end = begin + 1;
                projectedBreaks.append(begin);
            }
            QVERIFY(begin >= previousEnd); previousEnd = end;
        }
        QVector<int> authoredBreaks;
        for (const auto &boundary : owners.first().authoredBoundaries) authoredBreaks.append(boundary.character.position());
        QCOMPARE(projectedBreaks, authoredBreaks);
        const bool registered = LogicalFlow::registerOwners(&document, QVariantList{descriptor});
        if (!registered) qInfo().noquote() << "FLOW_REGISTRATION_DIAGNOSTIC" << QJsonDocument(QJsonObject{
            {QStringLiteral("descriptor"), QJsonObject::fromVariantMap(descriptor)},
            {QStringLiteral("source"), raw}, {QStringLiteral("count"), count},
            {QStringLiteral("frameFirst"), caption->firstPosition()},
            {QStringLiteral("frameLast"), caption->lastPosition()},
            {QStringLiteral("parentObject"), parent->objectIndex()}}).toJson(QJsonDocument::Compact);
        QVERIFY(registered);
        QCOMPARE(document.toRawText(), raw); QCOMPARE(document.characterCount(), count);
        QCOMPARE(caption->frameFormat(), captionFormat); QCOMPARE(caption->parentFrame(), parent);
        const auto ranges = FlowConstruction::ranges(owners.first());
        QCOMPARE(ranges.frames.value(2, -1), caption->objectIndex());
        for (const auto &boundary : ranges.authoredBoundaries) {
            QCOMPARE(boundary.sourceRun, 1);
            QCOMPARE(document.characterAt(boundary.character.position()), QChar(QChar::ParagraphSeparator));
            QVERIFY(!ranges.structuralJoins.contains(boundary.character.position()));
        }
        const auto scope = descriptor.value(QStringLiteral("parts")).toList().last().toMap();
        QCOMPARE(scope.value(QStringLiteral("kind")).toString(), QStringLiteral("scope"));
        QCOMPARE(scope.value(QStringLiteral("language")).toString(), QString());
        QCOMPARE(scope.value(QStringLiteral("language")).metaType().id(), int(QMetaType::QString));
        int widthIndex = 0;
        for (int width : {600, 300, 600}) {
            document.setTextWidth(width);
            QVERIFY(document.documentLayout()->documentSize().isValid());
            const QVariant error = document.documentLayout()->property("_wikidictParagraphBoxLayoutError");
            QCOMPARE(error.metaType().id(), int(QMetaType::Int)); QCOMPARE(error.toInt(), 0);
            for (int offset : {owners.first().first.position(), caption->firstPosition() - 1}) {
                const auto position = LogicalFlow::position(&document, offset);
                QCOMPARE(position.status, LogicalFlow::Status::Handled); QCOMPARE(position.error, 0);
            }
            const auto text = document.find(QStringLiteral("suffix")); QVERIFY(!text.isNull());
            const auto captionSelection = document.find(QStringLiteral("Real caption link")); QVERIFY(!captionSelection.isNull());
            QCOMPARE(captionSelection.selectedText(), QStringLiteral("Real caption link"));
            QCOMPARE(captionSelection.charFormat().anchorHref(), QStringLiteral("wikidict:cat"));
            QCOMPARE(document.toRawText(), raw);
            const QSize captureSize = document.documentLayout()->documentSize().toSize();
            QVERIFY(!captureSize.isEmpty());
            QImage capture(captureSize, QImage::Format_ARGB32_Premultiplied);
            capture.fill(Qt::white);
            { QPainter painter(&capture); document.drawContents(&painter); }
            QVERIFY(capture.save(QStringLiteral(".tmp/ui-screenshots/poem-registered-flow-%1-shell%2-step%3-width%4.png")
                .arg(QCoreApplication::applicationPid()).arg(shellIndex).arg(widthIndex++).arg(width)));
            const auto rectValues = [](const QRectF &rect) {
                return QJsonArray{rect.x(), rect.y(), rect.width(), rect.height()};
            };
            auto *nativeLayout = document.documentLayout();
            const QRectF captionBounds = nativeLayout->frameBoundingRect(caption);
            const auto captionBlock = document.findBlock(caption->firstPosition());
            const QRectF captionBlockBounds = nativeLayout->blockBoundingRect(captionBlock);
            QJsonArray captionLines;
            QJsonArray captionGlyphs;
            if (captionBlock.layout()) {
                for (int lineIndex = 0; lineIndex < captionBlock.layout()->lineCount(); ++lineIndex) {
                    const auto line = captionBlock.layout()->lineAt(lineIndex);
                    captionLines.append(QJsonObject{{QStringLiteral("index"), lineIndex},
                        {QStringLiteral("start"), line.textStart()}, {QStringLiteral("length"), line.textLength()},
                        {QStringLiteral("rect"), rectValues(line.rect())},
                        {QStringLiteral("width"), line.width()}, {QStringLiteral("advance"), line.horizontalAdvance()}});
                }
                for (int offset = captionBlock.position(); offset < captionBlock.position() + captionBlock.text().size(); ++offset) {
                    const int relative = offset - captionBlock.position();
                    const auto line = captionBlock.layout()->lineForTextPosition(relative);
                    if (!line.isValid()) continue;
                    QJsonArray bounds;
                    for (const auto &run : line.glyphRuns(relative, 1))
                        bounds.append(rectValues(run.boundingRect().translated(captionBlockBounds.topLeft())));
                    captionGlyphs.append(QJsonObject{{QStringLiteral("offset"), offset},
                        {QStringLiteral("codepoint"), int(document.characterAt(offset).unicode())},
                        {QStringLiteral("shapedSelectionBounds"), bounds}});
                }
            }
            QJsonArray sourceCharacters;
            bool validCharacterGeometry = captionBounds.isValid();
            bool bodyAvoidsCaption = true;
            const int poemLast = raw.indexOf(QStringLiteral("Poem last"));
            const std::array<std::pair<int, int>, 2> measuredRanges{{
                {poemLast, poemLast + int(QStringLiteral("Poem last").size())},
                {text.selectionStart(), text.selectionEnd()}}};
            for (const auto &[first, last] : measuredRanges) {
                validCharacterGeometry &= first >= 0 && first < last;
                for (int offset = qMax(0, first); offset < last; ++offset) {
                    const auto native = LogicalFlow::position(&document, offset);
                    QJsonObject values = QJsonObject::fromVariantMap(native.values);
                    for (const auto &key : {QStringLiteral("characterRect"), QStringLiteral("cursorRect")})
                        if (native.values.contains(key)) values.insert(key, rectValues(native.values.value(key).toRectF()));
                    const auto rectValue = native.values.value(QStringLiteral("characterRect"));
                    const QRectF cell = rectValue.toRectF();
                    const bool visibleUnit = !document.characterAt(offset).isSpace();
                    const bool valid = native.status == LogicalFlow::Status::Handled && native.error == 0
                        && LogicalFlow::finiteRect(rectValue) && (!visibleUnit || cell.isValid());
                    validCharacterGeometry &= valid;
                    const bool intersects = valid && visibleUnit && cell.intersects(captionBounds);
                    bodyAvoidsCaption &= !intersects;
                    const auto block = document.findBlock(offset);
                    const auto format = block.blockFormat();
                    QJsonObject row{{QStringLiteral("offset"), offset},
                        {QStringLiteral("codepoint"), int(document.characterAt(offset).unicode())},
                        {QStringLiteral("nativeStatus"), int(native.status)}, {QStringLiteral("nativeError"), native.error},
                        {QStringLiteral("native"), values}, {QStringLiteral("valid"), valid},
                        {QStringLiteral("intersectsCaptionFrame"), intersects},
                        {QStringLiteral("blockPosition"), block.position()},
                        {QStringLiteral("blockRect"), rectValues(nativeLayout->blockBoundingRect(block))},
                        {QStringLiteral("blockMargins"), QJsonArray{format.leftMargin(), format.topMargin(), format.rightMargin(), format.bottomMargin()}},
                        {QStringLiteral("blockDirection"), int(format.layoutDirection())}};
                    if (valid && cell.isValid()) {
                        row.insert(QStringLiteral("exactHit"), nativeLayout->hitTest(cell.center(), Qt::ExactHit));
                        row.insert(QStringLiteral("fuzzyHit"), nativeLayout->hitTest(cell.center(), Qt::FuzzyHit));
                    }
                    sourceCharacters.append(row);
                }
            }
            floatGeometryObservations.append(QJsonObject{{QStringLiteral("shell"), shellIndex},
                {QStringLiteral("widthStep"), widthIndex - 1}, {QStringLiteral("width"), width},
                {QStringLiteral("source"), raw}, {QStringLiteral("descriptor"), QJsonObject::fromVariantMap(descriptor)},
                {QStringLiteral("revision"), document.revision()}, {QStringLiteral("characterCount"), document.characterCount()},
                {QStringLiteral("cursorMoveStyle"), int(document.defaultCursorMoveStyle())},
                {QStringLiteral("captionFrame"), rectValues(captionBounds)},
                {QStringLiteral("captionFirst"), caption->firstPosition()}, {QStringLiteral("captionLast"), caption->lastPosition()},
                {QStringLiteral("captionFrameMargins"), QJsonArray{captionFormat.leftMargin(), captionFormat.topMargin(), captionFormat.rightMargin(), captionFormat.bottomMargin()}},
                {QStringLiteral("captionFramePadding"), captionFormat.padding()}, {QStringLiteral("captionFrameBorder"), captionFormat.border()},
                {QStringLiteral("captionParentFrame"), rectValues(nativeLayout->frameBoundingRect(parent))},
                {QStringLiteral("captionBlock"), rectValues(captionBlockBounds)},
                {QStringLiteral("captionLines"), captionLines}, {QStringLiteral("captionGlyphs"), captionGlyphs},
                {QStringLiteral("characters"), sourceCharacters}, {QStringLiteral("geometryValid"), validCharacterGeometry},
                {QStringLiteral("bodyAvoidsCaption"), bodyAvoidsCaption}});
            QFile geometryFile(QStringLiteral(".tmp/ui-screenshots/poem-float-geometry-%1.json")
                .arg(QCoreApplication::applicationPid()));
            QVERIFY(geometryFile.open(QIODevice::WriteOnly));
            const QByteArray geometryBytes = QJsonDocument(floatGeometryObservations).toJson(QJsonDocument::Indented);
            QCOMPARE(geometryFile.write(geometryBytes), qint64(geometryBytes.size()));
            geometryFile.close();
            QCOMPARE(document.toRawText(), raw);
            QCOMPARE(document.characterCount(), count);
            QVERIFY(validCharacterGeometry);
            allBodyAvoidsCaption &= bodyAvoidsCaption;
        }
        ++shellIndex;
        QVERIFY(LogicalFlow::registerOwners(&document, {}));
        auto unrelated = document.find(QStringLiteral("Poem first")); QVERIFY(!unrelated.isNull());
        unrelated.clearSelection(); unrelated.movePosition(QTextCursor::StartOfBlock);
        unrelated.movePosition(QTextCursor::NextCharacter);
        unrelated.insertBlock(); // Retains source-run formats but is not an owned figure insertion.
        QVERIFY_EXCEPTION_THROWN(FlowConstruction::descriptor(owners.first()), std::runtime_error);
        }
        QVERIFY2(allBodyAvoidsCaption, "Projected poem/suffix character bounds intersect the real floated caption frame");
    }

    void nativeFigureOperationRetainsFirstAndFinalOriginalBounds() {
        const auto marked = [](const QString &html, int run) {
            return SemanticHtml::scaledText(html, 1, {}, SemanticHtml::Basis::Context,
                0, false, false, false, 0, QJsonValue(), true, run);
        };
        const QJsonObject block{{"kind", "paragraph"}, {"spans", QJsonArray{}}, {"depth", 0}, {"list_path", ""}};
        for (const auto &pair : {qMakePair(QString(), QStringLiteral("Tail")),
                qMakePair(QStringLiteral("Head"), QString()), qMakePair(QString(), QString())}) {
            FlowConstruction::Rendered rendered;
            rendered.html = marked(pair.first, 1)
                + marked(QStringLiteral("<img src='wikidict-operation-test:figure'>"), 2) + marked(pair.second, 3);
            rendered.parts = QJsonArray{QJsonObject{{"kind", "inline"}, {"run", 1}},
                QJsonObject{{"kind", "figure"}, {"run", 2}}, QJsonObject{{"kind", "inline"}, {"run", 3}}};
            const QString role = QStringLiteral("<p style='margin:0'>Prefix:%1</p>");
            for (const QString &shell : {role, QStringLiteral("<p>Earlier</p>") + role,
                    QStringLiteral("<table><tr><td>Earlier cell</td><td>") + role + QStringLiteral("</td></tr></table>")}) {
                QTextDocument document;
                document.setHtml(shell.arg(FlowConstruction::placeholder(block, rendered, {QStringLiteral("en"), {}})));
                auto owners = FlowConstruction::expand(&document); QCOMPARE(owners.size(), 1);
                int position = -1;
                for (auto b = document.begin(); b.isValid(); b = b.next())
                    for (auto it = b.begin(); !it.atEnd(); ++it)
                        if (it.fragment().isValid() && it.fragment().charFormat().isImageFormat()
                            && it.fragment().charFormat().toImageFormat().name() == QStringLiteral("wikidict-operation-test:figure"))
                            position = it.fragment().position();
                QVERIFY(position >= 0);
                QString expected = document.toRawText();
                expected.replace(position, 1, QString(QChar(0xfdd0)) + QStringLiteral("Caption") + QChar(0xfdd1));
                QTextCursor image(&document); image.setPosition(position); image.setPosition(position + 1, QTextCursor::KeepAnchor);
                auto *parent = image.currentFrame();
                QTextFrameFormat format; format.setWidth(140);
                const auto frame = FlowConstruction::insertFigure(owners.first(), image, 2, format, [](QTextFrame *inserted) {
                    auto caption = inserted->firstCursorPosition(); caption.insertText(QStringLiteral("Caption"));
                });
                QVERIFY(frame); QCOMPARE(frame->parentFrame(), parent);
                QCOMPARE(owners.first().first.currentFrame(), parent);
                QCOMPARE(owners.first().last.currentFrame(), parent);
                QVERIFY(owners.first().last.position() >= frame->lastPosition() + 1);
                QVERIFY(owners.first().figureJoins.isEmpty());
                QCOMPARE(document.toRawText(), expected);
                const auto descriptor = FlowConstruction::descriptor(owners.first());
                QVERIFY(LogicalFlow::registerOwners(&document, QVariantList{descriptor}));
                QCOMPARE(document.toRawText(), expected);
                for (int width : {600, 280, 600}) {
                    document.setTextWidth(width);
                    QVERIFY(document.documentLayout()->documentSize().isValid());
                    const QVariant error = document.documentLayout()->property("_wikidictParagraphBoxLayoutError");
                    QCOMPARE(error.metaType().id(), int(QMetaType::Int)); QCOMPARE(error.toInt(), 0);
                    for (int offset : {owners.first().first.position(), frame->firstPosition() - 1}) {
                        const auto position = LogicalFlow::position(&document, offset);
                        QCOMPARE(position.status, LogicalFlow::Status::Handled); QCOMPARE(position.error, 0);
                    }
                    QCOMPARE(document.toRawText(), expected);
                    QCOMPARE(document.find(QStringLiteral("Caption")).selectedText(), QStringLiteral("Caption"));
                }
            }
        }
    }

    void nativeFigureOperationRejectsSynchronousReplacement() {
        QTextDocument document;
        FlowConstruction::Rendered rendered;
        rendered.html = SemanticHtml::scaledText(QStringLiteral("<img src='wikidict-operation-test:figure'>"),
            1, {}, SemanticHtml::Basis::Context, 0, false, false, false, 0, QJsonValue(), true, 2);
        rendered.parts = QJsonArray{QJsonObject{{"kind", "figure"}, {"run", 2}}};
        const QJsonObject block{{"kind", "paragraph"}, {"spans", QJsonArray{}}, {"depth", 0}, {"list_path", ""}};
        document.setHtml(QStringLiteral("<p>Prefix:%1</p>").arg(FlowConstruction::placeholder(block, rendered, {QStringLiteral("en"), {}})));
        auto owners = FlowConstruction::expand(&document); QCOMPARE(owners.size(), 1);
        QTextCursor image(&document); image.setPosition(owners.first().prefixEnd.position());
        image.setPosition(image.position() + 1, QTextCursor::KeepAnchor);
        bool replaced = false;
        connect(&document, &QTextDocument::contentsChanged, &document, [&] {
            if (replaced) return;
            replaced = true; document.setPlainText(QStringLiteral("Replacement survives"));
        });
        QTextFrameFormat format; format.setWidth(140);
        QVERIFY_EXCEPTION_THROWN(FlowConstruction::insertFigure(owners.first(), image, 2, format, [](QTextFrame *frame) {
            auto caption = frame->firstCursorPosition(); caption.insertText(QStringLiteral("Old caption"));
        }), std::runtime_error);
        QVERIFY(replaced); QCOMPARE(document.toPlainText(), QStringLiteral("Replacement survives"));
        QCOMPARE(document.rootFrame()->childFrames().size(), 0);
    }

    void compiledFigureSizingUsesReadyOriginalLogicalAxes() {
        using Policy = FigureSizing::Policy;
        using State = MediaPanel::InlineImageState;
        MediaPanel::InlineImageAsset asset{State::Ready, QImage(7, 11, QImage::Format_ARGB32),
            QString(), QSizeF(512, 420), QStringLiteral("image/svg+xml"), {}};
        const auto figure = [](const QString &format, const QString &policy, QJsonValue width, QJsonValue height) {
            return QJsonObject{{QStringLiteral("format"), format}, {QStringLiteral("sizing"), policy},
                {QStringLiteral("image_span"), QJsonObject{{QStringLiteral("image"), QJsonObject{
                    {QStringLiteral("width_px"), width}, {QStringLiteral("height_px"), height}}}}}};
        };
        struct Row { Policy policy; quint32 ow, oh; std::optional<quint32> width, height; QSizeF expected; };
        const QVector<Row> rows{
            {Policy::Intrinsic, 512, 420, 400, 100, {512, 420}},
            {Policy::Intrinsic, 512, 420, {}, {}, {512, 420}},
            {Policy::OriginalWidthWithHeightBound, 512, 420, 400, 100, {122, 100}},
            {Policy::OriginalWidthWithHeightBound, 512, 420, {}, 600, {512, 420}},
            {Policy::RequestedFit, 512, 420, 400, {}, {400, 328}},
            {Policy::RequestedFitCapOriginalWidth, 512, 420, 400, {}, {400, 328}},
            {Policy::RequestedFit, 512, 420, 1024, {}, {1024, 840}},
            {Policy::RequestedFitCapOriginalWidth, 512, 420, 1024, {}, {512, 420}},
            {Policy::RequestedFit, 512, 420, 1200, 600, {732, 600}},
            {Policy::RequestedFitCapOriginalWidth, 512, 420, 1200, 600, {512, 420}},
            {Policy::RequestedFit, 5, 4, 10, 1, {1, 1}},
            {Policy::RequestedFit, 2, 1, 1, {}, {1, 1}},
            {Policy::RequestedFit, 3, 1, 1, {}, {1, 0}},
            {Policy::RequestedFit, 1, 1000, 10, 1, {1, 1}}
        };
        for (const auto &row : rows) {
            asset.intrinsic = QSizeF(row.ow, row.oh);
            const auto result = FigureSizing::resolve({row.policy, row.width, row.height}, asset);
            QVERIFY(result.has_value()); QCOMPARE(*result, row.expected);
        }
        const QStringList policies{QStringLiteral("intrinsic"), QStringLiteral("original_width_with_height_bound"),
            QStringLiteral("requested_fit"), QStringLiteral("requested_fit_cap_original_width")};
        for (int at = 0; at < policies.size(); ++at) {
            const QString format = at < 2 ? QStringLiteral("framed") : QStringLiteral("thumbnail");
            const auto authored = figure(format, policies[at], 400, 100);
            const auto before = QJsonDocument(authored).toJson(QJsonDocument::Compact);
            const auto request = FigureSizing::request(authored);
            QVERIFY(request.width == std::optional<quint32>{400});
            QVERIFY(request.height == std::optional<quint32>{100});
            QCOMPARE(QJsonDocument(authored).toJson(QJsonDocument::Compact), before);
            const auto wrongFormat = figure(at < 2 ? QStringLiteral("thumbnail") : QStringLiteral("framed"), policies[at], 400, 100);
            QVERIFY_EXCEPTION_THROWN(FigureSizing::request(wrongFormat), std::runtime_error);
            QVERIFY_EXCEPTION_THROWN(FigureSizing::request(figure(format, policies[at], 0, 100)), std::runtime_error);
            QVERIFY_EXCEPTION_THROWN(FigureSizing::request(figure(format, policies[at], 400, 0)), std::runtime_error);
            if (at == 1) QVERIFY_EXCEPTION_THROWN(FigureSizing::request(figure(format, policies[at], 400, QJsonValue::Null)), std::runtime_error);
            if (at >= 2) QVERIFY_EXCEPTION_THROWN(FigureSizing::request(figure(format, policies[at], QJsonValue::Null, 100)), std::runtime_error);
        }
        auto missing = figure(QStringLiteral("framed"), QStringLiteral("intrinsic"), QJsonValue::Null, QJsonValue::Null);
        missing.remove(QStringLiteral("sizing"));
        QVERIFY_EXCEPTION_THROWN(FigureSizing::request(missing), std::runtime_error);
        QVERIFY_EXCEPTION_THROWN(FigureSizing::request(figure(QStringLiteral("framed"), QStringLiteral("unknown"), 1, 1)), std::runtime_error);
        const FigureSizing::Request request{Policy::RequestedFit, 400, {}};
        asset.intrinsic = QSizeF(512, 420);
        for (State state : {State::Disabled, State::Loading, State::Error}) {
            asset.state = state; QVERIFY(!FigureSizing::resolve(request, asset));
        }
        asset.state = State::Ready;
        for (QSizeF size : {QSizeF(), QSizeF(0, 2), QSizeF(-1, 2), QSizeF(1.5, 2),
                QSizeF(std::numeric_limits<qreal>::infinity(), 2), QSizeF(std::numeric_limits<qreal>::quiet_NaN(), 2),
                QSizeF(4294967296.0, 2)}) {
            asset.intrinsic = size; QVERIFY(!FigureSizing::resolve(request, asset));
        }
        asset.intrinsic = QSizeF(512, 420);
        asset.image.setDevicePixelRatio(3);
        asset.originalMime = QStringLiteral("unrelated/type");
        const auto independent = FigureSizing::resolve(request, asset);
        QVERIFY(independent.has_value()); QCOMPARE(*independent, QSizeF(400, 328));
        asset.intrinsic = QSizeF(1, 4294967295.0);
        QVERIFY(!FigureSizing::resolve({Policy::RequestedFit, 4294967295U, {}}, asset)); // Exact qreal conversion unavailable.
        QVERIFY(!FigureSizing::product(std::numeric_limits<quint64>::max(), 2));
        QVERIFY(!FigureSizing::positiveRound(1, 0));
    }

    void paragraphBoxTypedEdgesKeepEmptyAndNeighborContributions() {
        const auto length = [](double n, const QString &unit = QStringLiteral("px")) {
            return QJsonObject{{"unit", unit}, {"value", n}};
        };
        const auto edges = [&](double top, double right, double bottom, double left, const QString &unit = QStringLiteral("px")) {
            return QJsonObject{{"top", length(top, unit)}, {"right", length(right, unit)},
                {"bottom", length(bottom, unit)}, {"left", length(left, unit)}};
        };
        QJsonObject block{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", QJsonArray{}}};
        QVERIFY(!ParagraphBox::source(block));
        block.insert("style", QJsonObject{{"padding", edges(1, 2, 3, 4)}});
        const auto paddingSource = ParagraphBox::source(block); QVERIFY(paddingSource);
        const auto inherited = ParagraphBox::resolve(*paddingSource, {7, 0, 11, 0}, 16); QVERIFY(inherited);
        QCOMPARE(inherited->margins[ParagraphBox::Top], qreal(7));
        QCOMPARE(inherited->margins[ParagraphBox::Bottom], qreal(11));
        QVERIFY(!inherited->authoredMargins);
        const auto legacyEmpty = ParagraphBox::resolve(*paddingSource, {}, 16); QVERIFY(legacyEmpty);
        QCOMPARE(*ParagraphBox::first(*legacyEmpty), qreal(1));
        QCOMPARE(*ParagraphBox::last(*legacyEmpty), qreal(3));
        block.insert("style", QJsonObject{{"margins", edges(0, 0, 0, 0)}, {"padding", edges(1, 2, 3, 4)}});
        const auto explicitZero = ParagraphBox::resolve(*ParagraphBox::source(block), {7, 0, 11, 0}, 16); QVERIFY(explicitZero);
        QVERIFY(explicitZero->authoredMargins);
        QCOMPARE(explicitZero->margins, ParagraphBox::Edges({0, 0, 0, 0}));
        QCOMPARE(explicitZero->padding, inherited->padding);

        const ParagraphBox::Resolved before{{0, 0, 9, 0}, {0, 0, 2, 0}, true};
        const ParagraphBox::Resolved empty{{5, 0, 13, 0}, {}, true};
        const ParagraphBox::Resolved after{{6, 0, 0, 0}, {4, 0, 0, 0}, true};
        QCOMPARE(*ParagraphBox::boundary(before, empty, true), qreal(11));
        QCOMPARE(*ParagraphBox::boundary(empty, after, true), qreal(17));
        auto paddedEmpty = empty; paddedEmpty.padding = {3, 4, 5, 6};
        QCOMPARE(*ParagraphBox::boundary(before, paddedEmpty, true), qreal(14));
        QCOMPARE(*ParagraphBox::boundary(paddedEmpty, after, true), qreal(22));
        QCOMPARE(*ParagraphBox::boundary(before, empty, false), qreal(16));
        QCOMPARE(*ParagraphBox::boundary(empty, after, false), qreal(23));
        // The parser never filters an empty owner's explicit values or inserts text.
        QCOMPARE(block.value("spans").toArray().size(), 0);

        block.insert("style", QJsonObject{{"margins", edges(.5, 1, 2, 3, QStringLiteral("em"))}});
        const auto em = ParagraphBox::resolve(*ParagraphBox::source(block), {}, 16); QVERIFY(em);
        QCOMPARE(em->margins, ParagraphBox::Edges({8, 16, 32, 48}));
        // Large legal finite-f32 values remain source data and refuse native fit.
        block.insert("style", QJsonObject{{"padding", edges(0, 0, double(std::numeric_limits<float>::max()), 0, QStringLiteral("em"))}});
        const auto huge = ParagraphBox::source(block); QVERIFY(huge);
        QVERIFY(!ParagraphBox::resolve(*huge, {}, 16));
        const ParagraphBox::Resolved nearLimit{{0, 0, 8388607, 0}, {0, 0, 1, 0}, true};
        QVERIFY(!ParagraphBox::boundary(nearLimit, after, true));
        block.insert("style", QJsonObject{});
        QVERIFY_EXCEPTION_THROWN(ParagraphBox::source(block), std::runtime_error);
        block.insert("style", QJsonObject{{"padding", edges(1, 1, 1, 1)}});
        block.insert("kind", "heading");
        QVERIFY_EXCEPTION_THROWN(ParagraphBox::source(block), std::runtime_error);
    }

    void compiledLogicalFormatUpdatesKeepRegisteredSource() {
        QTextDocument document;
        document.setDocumentMargin(0);
        document.setTextWidth(360);
        QTextCursor cursor(&document);
        cursor.insertText(QStringLiteral("Prefix "));
        QTextImageFormat imageFormat;
        imageFormat.setName(QStringLiteral("test-owned-format-image"));
        imageFormat.setWidth(20);
        imageFormat.setHeight(10);
        const int imagePosition = cursor.position();
        cursor.insertImage(imageFormat);
        cursor.insertText(QStringLiteral(" suffix"));
        const QString source = document.toRawText();
        const int last = document.characterCount() - 1;
        const QVariantList owners{QVariantMap{
            {QStringLiteral("first"), 0}, {QStringLiteral("last"), last},
            {QStringLiteral("direction"), int(Qt::LeftToRight)},
            {QStringLiteral("joins"), QVariantList{}},
            {QStringLiteral("parts"), QVariantList{QVariantMap{
                {QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("first"), 0}, {QStringLiteral("last"), last}}}}}};
        QVERIFY(LogicalFlow::registerOwners(&document, owners));
        const auto layout = QPointer<QAbstractTextDocumentLayout>(document.documentLayout());
        QVERIFY(layout);
        const auto forceLayout = [&] {
            document.documentLayout()->documentSize();
            return document.documentLayout() == layout
                && layout->property("_wikidictParagraphBoxLayoutError").metaType().id() == QMetaType::Int
                && layout->property("_wikidictParagraphBoxLayoutError").toInt() == 0
                && LogicalFlow::position(&document, imagePosition).status == LogicalFlow::Status::Handled;
        };
        QVERIFY(forceLayout());
        const int beforeRevision = document.revision();
        const auto updated = LogicalFlow::editFormats(&document, owners, beforeRevision, [&] {
            QTextCursor image(&document);
            image.setPosition(imagePosition);
            image.setPosition(imagePosition + 1, QTextCursor::KeepAnchor);
            auto changed = image.charFormat().toImageFormat();
            changed.setWidth(48);
            changed.setHeight(24);
            image.setCharFormat(changed);
        });
        QVERIFY(updated.has_value());
        QCOMPARE(*updated, document.revision());
        QVERIFY(*updated != beforeRevision);
        QCOMPARE(document.toRawText(), source);
        QCOMPARE(document.characterCount() - 1, last);
        QVERIFY(forceLayout());
        QTextCursor selected(&document);
        selected.setPosition(imagePosition);
        selected.setPosition(imagePosition + 1, QTextCursor::KeepAnchor);
        QCOMPARE(selected.charFormat().toImageFormat().width(), qreal(48));
        QCOMPARE(selected.charFormat().toImageFormat().height(), qreal(24));

        // A same-length source edit is not a format update and may not acquire a
        // fresh registration merely because all original offsets still fit.
        const int stableRevision = document.revision();
        const auto refused = LogicalFlow::editFormats(&document, owners, stableRevision, [&] {
            QTextCursor text(&document);
            text.setPosition(0);
            text.setPosition(1, QTextCursor::KeepAnchor);
            text.insertText(QStringLiteral("Q"));
        });
        QVERIFY(!refused.has_value());
        QCOMPARE(document.characterCount() - 1, last);
        QCOMPARE(document.toRawText().left(1), QStringLiteral("Q"));
        const auto stale = LogicalFlow::position(&document, imagePosition);
        QCOMPARE(stale.status, LogicalFlow::Status::Refused);
        QCOMPARE(stale.error, 5);
        QVERIFY(document.isLayoutEnabled());

        // An unrelated revision cannot be silently legitimized on entry either.
        bool called = false;
        QVERIFY(!LogicalFlow::editFormats(&document, owners, stableRevision, [&] { called = true; }).has_value());
        QVERIFY(!called);

        QTextDocument framed;
        framed.setTextWidth(400);
        QTextCursor parent(&framed);
        parent.insertText(QStringLiteral("before "));
        QTextFrameFormat frameFormat;
        frameFormat.setWidth(100);
        frameFormat.setMargin(0);
        frameFormat.setProperty(QTextFormat::UserProperty + 0x57a0, QStringLiteral("wikidict.figure-layout/1"));
        frameFormat.setProperty(QTextFormat::UserProperty + 0x57a1, 0);
        frameFormat.setProperty(QTextFormat::UserProperty + 0x57a2, 0);
        QPointer<QTextFrame> frame = parent.insertFrame(frameFormat);
        frame->firstCursorPosition().insertText(QStringLiteral("real caption"));
        parent.setPosition(frame->lastPosition() + 1);
        parent.insertText(QStringLiteral(" after"));
        const QString framedText = framed.toRawText();
        const int framedLast = framed.characterCount() - 1;
        const QVariantList framedOwners{QVariantMap{
            {QStringLiteral("first"), 0}, {QStringLiteral("last"), framedLast},
            {QStringLiteral("direction"), int(Qt::LeftToRight)}, {QStringLiteral("joins"), QVariantList{}},
            {QStringLiteral("parts"), QVariantList{
                QVariantMap{{QStringLiteral("kind"), QStringLiteral("text")},
                    {QStringLiteral("first"), 0}, {QStringLiteral("last"), frame->firstPosition() - 1}},
                QVariantMap{{QStringLiteral("kind"), QStringLiteral("frame")},
                    {QStringLiteral("object"), frame->objectIndex()}},
                QVariantMap{{QStringLiteral("kind"), QStringLiteral("text")},
                    {QStringLiteral("first"), frame->lastPosition() + 1}, {QStringLiteral("last"), framedLast}}}}}};
        QVERIFY(LogicalFlow::registerOwners(&framed, framedOwners));
        const int first = frame->firstPosition(), end = frame->lastPosition(), object = frame->objectIndex();
        const auto resized = LogicalFlow::editFormats(&framed, framedOwners, framed.revision(), [&] {
            auto format = frame->frameFormat();
            format.setWidth(180);
            frame->setFrameFormat(format);
        });
        QVERIFY(resized.has_value());
        QVERIFY(frame);
        QCOMPARE(frame->firstPosition(), first);
        QCOMPARE(frame->lastPosition(), end);
        QCOMPARE(frame->objectIndex(), object);
        QCOMPARE(framed.toRawText(), framedText);
        framed.documentLayout()->documentSize();
        QCOMPARE(framed.documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
        QCOMPARE(LogicalFlow::position(&framed, 0).status, LogicalFlow::Status::Handled);
        QCOMPARE(frame->frameFormat().width().rawValue(), qreal(180));
    }

    void sourceRunMetadataPreservesWholeImportedTextAndFormatting() {
        MainWindow window{QString()};
        const QJsonArray spans{
            QJsonObject{{"kind", "text"}, {"text", "  "}},
            QJsonObject{{"kind", "text"}, {"text", "Marked "}, {"bold", true}},
            QJsonObject{{"kind", "link"}, {"text", "linked"}, {"target", "cat"},
                {"tooltip", "<b>literal advice</b>"}, {"explanation", "separate expansion"}},
            QJsonObject{{"kind", "line_break"}, {"text", ""}, {"tooltip", "break advice"}, {"explanation", "break expansion"}},
            QJsonObject{{"kind", "text"}, {"text", "Second \u05d0\u05d1\u05d2 "}, {"italic", true}},
            QJsonObject{{"kind", "text"}, {"text", "scaled"}, {"font_scale", 1.5}},
            QJsonObject{{"kind", "text"}, {"text", "hidden"}, {"font_scale", 0.0}},
            QJsonObject{{"kind", "text"}, {"text", " AV "}, {"direction", "ltr"}},
            QJsonObject{{"kind", "link"}, {"text", "\u05d0\u05d1\u05d2"}, {"target", "dog"}, {"direction", "rtl"}},
            QJsonObject{{"kind", "text"}, {"text", "\u0644\u0627e\u0301"}, {"direction", "auto"}},
            QJsonObject{{"kind", "text"}, {"text", ""}, {"tooltip", "empty source advice"}}};
        QTextDocument baseline, owned;
        const QFont font(QStringLiteral("DejaVu Sans"), 12);
        baseline.setDefaultFont(font); owned.setDefaultFont(font);
        SemanticHtml::setHtml(&baseline, window.spansHtml(spans, 0, {}, {}, 12));
        SemanticHtml::setHtml(&owned, window.spansHtml(spans, 0, {}, {}, 12, {}, 27));
        QCOMPARE(owned.toRawText(), baseline.toRawText());
        QCOMPARE(owned.toPlainText(), baseline.toPlainText());
        QCOMPARE(owned.toHtml(), baseline.toHtml());
        QCOMPARE(owned.characterCount(), baseline.characterCount());
        const auto formatAt = [](QTextDocument &document, int position) {
            const auto block = document.findBlock(position);
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (fragment.isValid() && fragment.contains(position)) return fragment.charFormat();
            }
            return QTextCharFormat{};
        };
        bool sawBreak = false, sawLink = false, sawZero = false;
        for (int position = 0; position < owned.characterCount() - 1; ++position) {
            if (owned.characterAt(position) == QChar::ParagraphSeparator) continue;
            auto actual = formatAt(owned, position);
            QVERIFY(actual.hasProperty(SemanticHtml::sourceRunProperty));
            QCOMPARE(actual.property(SemanticHtml::sourceRunProperty).metaType().id(), int(QMetaType::Int));
            QCOMPARE(actual.intProperty(SemanticHtml::sourceRunProperty), 27);
            actual.clearProperty(SemanticHtml::sourceRunProperty);
            QCOMPARE(actual, formatAt(baseline, position));
            sawBreak |= owned.characterAt(position) == QChar::LineSeparator;
            sawLink |= actual.isAnchor() && !actual.anchorHref().isEmpty();
            sawZero |= actual.property(QTextFormat::FontFamilies).toStringList().contains(SemanticHtml::zeroFontFamilyName);
        }
        QVERIFY(sawBreak); QVERIFY(sawLink); QVERIFY(sawZero);
        for (ushort isolate : {ushort(0x2066), ushort(0x2067), ushort(0x2068)})
            QCOMPARE(owned.toRawText().count(QChar(isolate)), 1);
        QCOMPARE(owned.toRawText().count(QChar(0x2069)), 3);
        for (qreal width : {qreal(400), qreal(180), qreal(400)}) {
            baseline.setTextWidth(width); owned.setTextWidth(width);
            QCOMPARE(owned.documentLayout()->documentSize(), baseline.documentLayout()->documentSize());
            for (auto block = baseline.begin(); block.isValid(); block = block.next()) {
                const auto actual = owned.findBlock(block.position());
                QVERIFY(actual.isValid());
                QCOMPARE(owned.documentLayout()->blockBoundingRect(actual),
                         baseline.documentLayout()->blockBoundingRect(block));
                QCOMPARE(actual.layout()->lineCount(), block.layout()->lineCount());
                for (int line = 0; line < block.layout()->lineCount(); ++line) {
                    const auto expectedLine = block.layout()->lineAt(line);
                    const auto actualLine = actual.layout()->lineAt(line);
                    QCOMPARE(actualLine.textStart(), expectedLine.textStart());
                    QCOMPARE(actualLine.textLength(), expectedLine.textLength());
                    QCOMPARE(actualLine.rect(), expectedLine.rect());
                    QCOMPARE(actualLine.naturalTextWidth(), expectedLine.naturalTextWidth());
                    for (int offset = expectedLine.textStart();
                         offset <= expectedLine.textStart() + expectedLine.textLength(); ++offset)
                        QCOMPARE(actualLine.cursorToX(offset), expectedLine.cursorToX(offset));
                }
            }
        }
        const auto linked = owned.find(QStringLiteral("linked")); QVERIFY(!linked.isNull());
        QCOMPARE(linked.charFormat().stringProperty(SemanticHtml::spanAdvisoryProperty), QStringLiteral("<b>literal advice</b>"));
        QCOMPARE(linked.charFormat().stringProperty(SemanticHtml::spanExpansionProperty), QStringLiteral("separate expansion"));
        // Whole-owner import preserves whitespace decisions across run boundaries.
        const QJsonArray first{QJsonObject{{"kind", "text"}, {"text", "A "}}};
        const QJsonArray second{QJsonObject{{"kind", "text"}, {"text", " B"}}};
        const QString allHtml = window.spansHtml(first, 0, {}, {}, 12, {}, 1)
            + window.spansHtml(second, 0, {}, {}, 12, {}, 2);
        SemanticHtml::setHtml(&owned, allHtml);
        SemanticHtml::setHtml(&baseline, window.spansHtml(first, 0, {}, {}, 12) + window.spansHtml(second, 0, {}, {}, 12));
        QCOMPARE(owned.toRawText(), baseline.toRawText());
        QCOMPARE(owned.toHtml(), baseline.toHtml());
        const auto a = owned.find(QStringLiteral("A")), b = owned.find(QStringLiteral("B"));
        QVERIFY(!a.isNull()); QVERIFY(!b.isNull());
        QCOMPARE(a.charFormat().intProperty(SemanticHtml::sourceRunProperty), 1);
        QCOMPARE(b.charFormat().intProperty(SemanticHtml::sourceRunProperty), 2);
    }

    void figureCaptionImportTransfersOnlyFirstBlockFormat() {
        // The previous saved cursor kept position but selected the imported
        // fragment as its anchor advanced. Later authored formats must survive.
        for (int location : {0, 1, 2}) {
            QTextDocument document;
            QTextCursor cursor(&document);
            if (location == 1) { cursor.insertText(QStringLiteral("Earlier")); cursor.insertBlock(); }
            if (location == 2) {
                QTextTableFormat format; format.setCellPadding(7);
                auto *table = cursor.insertTable(1, 2, format);
                table->cellAt(0, 0).firstCursorPosition().insertText(QStringLiteral("Other cell"));
                cursor = table->cellAt(0, 1).firstCursorPosition();
            }
            QTextFrameFormat frameFormat; frameFormat.setMargin(0); frameFormat.setPadding(0);
            auto *frame = cursor.insertFrame(frameFormat);
            const QString html = QStringLiteral(
                "<p data-wikidict-source-run=\"101\" style='margin:0;margin-left:11px;font-size:17pt'>First</p>"
                "<p data-wikidict-source-run=\"102\" dir='rtl' style='-qt-paragraph-type:empty;margin:0;margin-left:3px;font-size:19pt'><br></p>"
                "<p data-wikidict-source-run=\"103\" style='margin:0;margin-left:7px;font-size:13pt'>Last</p>"
                "<table width='73'><tr><td style='font-size:21pt'>Cell</td></tr></table>");
            SemanticFigure::insertHtml(frame->firstCursorPosition(), html, 10.608, Qt::AlignRight | Qt::AlignAbsolute);
            const auto first = document.find(QStringLiteral("First")); QVERIFY(!first.isNull());
            QCOMPARE(first.blockFormat().intProperty(SemanticHtml::sourceRunProperty), 101);
            QCOMPARE(first.blockFormat().leftMargin(), qreal(11));
            QCOMPARE(first.charFormat().fontPointSize(), qreal(17));
            const auto empty = first.block().next(); QVERIFY(empty.isValid() && empty.text().isEmpty());
            QCOMPARE(empty.blockFormat().intProperty(SemanticHtml::sourceRunProperty), 102);
            QCOMPARE(empty.blockFormat().leftMargin(), qreal(3));
            QCOMPARE(empty.blockFormat().layoutDirection(), Qt::RightToLeft);
            QCOMPARE(empty.charFormat().fontPointSize(), qreal(19));
            QVERIFY(empty.isVisible());
            const auto last = document.find(QStringLiteral("Last")); QVERIFY(!last.isNull());
            QCOMPARE(last.blockFormat().intProperty(SemanticHtml::sourceRunProperty), 103);
            QCOMPARE(last.blockFormat().leftMargin(), qreal(7));
            QCOMPARE(last.charFormat().fontPointSize(), qreal(13));
            const auto cell = document.find(QStringLiteral("Cell"), 0, QTextDocument::FindCaseSensitively);
            QVERIFY(!cell.isNull() && cell.currentTable());
            QCOMPARE(cell.selectedText(), QStringLiteral("Cell"));
            auto *captionTable = cell.currentTable();
            QCOMPARE(captionTable->parentFrame(), frame);
            QCOMPARE(captionTable->rows(), 1); QCOMPARE(captionTable->columns(), 1);
            const auto nativeCell = captionTable->cellAt(cell);
            QVERIFY(nativeCell.isValid()); QCOMPARE(nativeCell.row(), 0); QCOMPARE(nativeCell.column(), 0);
            QCOMPARE(captionTable->format().width().rawValue(), qreal(73));
            QCOMPARE(cell.charFormat().fontPointSize(), qreal(21));
            QCOMPARE(document.toPlainText().count(QStringLiteral("First")), 1);
            QCOMPARE(document.toPlainText().count(QStringLiteral("Last")), 1);
            QCOMPARE(document.toPlainText().count(QStringLiteral("Cell")), 1);
            QCOMPARE(empty.position(), first.block().position() + first.block().length());
            QCOMPARE(last.block().position(), empty.position() + empty.length());
            const QString raw = document.toRawText();
            for (int width : {600, 320, 600}) {
                document.setTextWidth(width); document.size();
                QCOMPARE(document.toRawText(), raw);
                QCOMPARE(empty.blockFormat().intProperty(SemanticHtml::sourceRunProperty), 102);
                QVERIFY(document.documentLayout()->blockBoundingRect(empty).height() > 0);
            }
        }
    }

    void compiledFiguresKeepRichCaptionOwnershipAndReadySizing() {
        const auto length = [](qreal value) { return QJsonObject{{"unit", "px"}, {"value", value}}; };
        const auto edges = [&](qreal top, qreal right, qreal bottom, qreal left) {
            return QJsonObject{{"top", length(top)}, {"right", length(right)}, {"bottom", length(bottom)}, {"left", length(left)}};
        };
        const QJsonObject image{{"file", "Controlled figure.png"}, {"width_px", 20}, {"height_px", QJsonValue()},
            {"alt", "Controlled image"}, {"tooltip", "Image advice"}, {"border", true}};
        const auto makeFigure = [&] {
            return QJsonObject{{"image_span", QJsonObject{{"kind", "text"}, {"text", ""}, {"image", image}}},
                {"format", "thumbnail"}, {"sizing", "requested_fit"}, {"placement", "none"}, {"clear", "none"},
                {"margins", edges(2, 3, 4, 5)}, {"image_insets", edges(1, 2, 3, 4)},
                {"caption_padding", edges(2, 4, 3, 5)}, {"caption_font_scale", .884}, {"caption_line_height", length(18)},
                {"frame_background", QJsonObject{{"kind", "transparent"}}}, {"frame_border", QJsonObject{{"kind", "none"}}},
                {"image_background", QJsonObject{{"kind", "transparent"}}}, {"image_border", QJsonObject{{"kind", "none"}}},
                {"caption_foreground", QJsonObject{{"kind", "rgb"}, {"value", "#154360"}}},
                {"caption_background", QJsonObject{{"kind", "transparent"}}}, {"caption", QJsonArray{}},
                {"caption_blocks", QJsonArray{}}, {"caption_text_align", "right"}};
        };
        const QJsonObject paragraph{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", QJsonArray{}}};
        const QPalette palette;
        const QString imageHtml = QStringLiteral("<a href='wikidict:cat'>") + SemanticHtml::inlineImageHtml(image) + QStringLiteral("</a>");
        const auto marked = [](const QString &html, int run) {
            return SemanticHtml::scaledText(html, 1, {}, SemanticHtml::Basis::Context,
                0, false, false, false, 0, QJsonValue(), true, run);
        };
        auto nestedFigure = makeFigure();
        nestedFigure.insert("placement", "float_right");
        FlowConstruction::Rendered nested;
        nested.html = marked(SemanticFigure::placeholder(nestedFigure, imageHtml, {}, false, 16, 10.608, "right", palette), 21);
        nested.parts = QJsonArray{QJsonObject{{"kind", "figure"}, {"run", 21}}};
        const QString nestedPlaceholder = FlowConstruction::placeholder(paragraph, nested, {QStringLiteral("en"), {}});
        const QString captionHtml = QStringLiteral("<p data-wikidict-source-run=\"44\" dir='rtl' style='margin:0;margin-left:11px;font-size:17pt'>"
            "Caption <a href='wikidict:dog'>linked</a><span style='color:transparent'> invisible</span></p>"
            "<p data-wikidict-source-run=\"45\" style='-qt-paragraph-type:empty;margin:0'><br></p>"
            "<table width='73' border='1'><tr><td style='font-size:21pt'>Cell</td></tr></table><p>Nested:%1</p>").arg(nestedPlaceholder);
        auto figure = makeFigure();
        figure.insert("caption_blocks", QJsonArray{QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{QJsonObject{{"text", "Caption"}}}}}});
        FlowConstruction::Rendered rendered;
        rendered.html = marked(QStringLiteral("Before "), 1)
            + marked(SemanticFigure::placeholder(figure, imageHtml, captionHtml, true, 16, 10.608, "right", palette), 2)
            + marked(QStringLiteral(" After"), 3);
        rendered.parts = QJsonArray{QJsonObject{{"kind", "inline"}, {"run", 1}}, QJsonObject{{"kind", "figure"}, {"run", 2}},
            QJsonObject{{"kind", "inline"}, {"run", 3}}};
        const QString role = QStringLiteral("<p style='margin:0'>Role: %1</p>");
        for (const QString &shell : {role, QStringLiteral("<p>Earlier</p>") + role + QStringLiteral("<p>Later</p>"),
                QStringLiteral("<table><tr><td>First cell</td><td>") + role + QStringLiteral("</td></tr></table>")}) {
            QTextDocument document;
            document.setDefaultFont(QFont(QStringLiteral("DejaVu Sans"), 12));
            document.setHtml(shell.arg(FlowConstruction::placeholder(paragraph, rendered, {QStringLiteral("en"), {}})));
            InlineVectorImages handler(document.documentLayout());
            auto owners = FlowConstruction::expand(&document); QCOMPARE(owners.size(), 1);
            const QString beforeMaterialize = document.toRawText();
            QVERIFY_EXCEPTION_THROWN(SemanticFigure::materialize(&document, owners, palette), std::runtime_error);
            QCOMPARE(document.toRawText(), beforeMaterialize);
            document.setLayoutEnabled(false);
            const auto outerFrames = SemanticFigure::materialize(&document, owners, palette); QCOMPARE(outerFrames.size(), 1);
            const auto outer = outerFrames.first(); QVERIFY(outer);
            auto nestedOwners = FlowConstruction::expand(&document); QCOMPARE(nestedOwners.size(), 1);
            const auto nestedFrames = SemanticFigure::materialize(&document, nestedOwners, palette); QCOMPARE(nestedFrames.size(), 1);
            owners += nestedOwners;
            QVERIFY(outer && nestedFrames.first());
            for (auto *frame : {outer.data(), nestedFrames.first().data()}) {
                const auto clear = frame->frameFormat().property(SemanticFigure::clearProperty);
                QCOMPARE(clear.metaType().id(), int(QMetaType::Int)); QCOMPARE(clear.toInt(), 0);
            }
            QCOMPARE(document.toPlainText().count(QStringLiteral("Role:")), 1);
            QCOMPARE(document.toPlainText().count(QStringLiteral("Caption")), 1);
            QCOMPARE(document.toPlainText().count(QStringLiteral("Nested:")), 1);
            QCOMPARE(document.toPlainText().count(QStringLiteral("Before")), 1);
            QCOMPARE(document.toPlainText().count(QStringLiteral("After")), 1);
            QVERIFY(owners.first().figureJoins.isEmpty());
            const auto captionText = document.find(QStringLiteral("Caption")); QVERIFY(!captionText.isNull());
            QCOMPARE(captionText.blockFormat().leftMargin(), qreal(11));
            QCOMPARE(captionText.blockFormat().layoutDirection(), Qt::RightToLeft);
            QVERIFY(captionText.blockFormat().alignment().testFlag(Qt::AlignAbsolute));
            QVERIFY(captionText.blockFormat().alignment().testFlag(Qt::AlignRight));
            QCOMPARE(captionText.blockFormat().intProperty(SemanticHtml::sourceRunProperty), 44);
            QCOMPARE(captionText.charFormat().fontPointSize(), qreal(17));
            QCOMPARE(captionText.charFormat().foreground().color(), QColor(QStringLiteral("#154360")));
            const auto invisible = document.find(QStringLiteral("invisible")); QVERIFY(!invisible.isNull());
            QCOMPARE(invisible.charFormat().foreground().color().alpha(), 0);
            const auto link = document.find(QStringLiteral("linked")); QVERIFY(!link.isNull());
            QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("wikidict:dog"));
            auto empty = captionText.block().next(); QVERIFY(empty.isValid() && empty.text().isEmpty());
            QCOMPARE(empty.blockFormat().intProperty(SemanticHtml::sourceRunProperty), 45);
            QVERIFY(empty.isVisible());
            const auto cellText = document.find(QStringLiteral("Cell"), 0, QTextDocument::FindCaseSensitively);
            QVERIFY(!cellText.isNull()); QCOMPARE(cellText.selectedText(), QStringLiteral("Cell"));
            auto *captionTable = cellText.currentTable(); QVERIFY(captionTable);
            QCOMPARE(captionTable->parentFrame(), captionText.currentFrame());
            QCOMPARE(captionTable->rows(), 1); QCOMPARE(captionTable->columns(), 1);
            const auto nativeCell = captionTable->cellAt(cellText);
            QVERIFY(nativeCell.isValid()); QCOMPARE(nativeCell.row(), 0); QCOMPARE(nativeCell.column(), 0);
            const auto captionTableFormat = captionTable->format();
            QCOMPARE(captionTableFormat.width().rawValue(), qreal(73));
            QCOMPARE(cellText.charFormat().fontPointSize(), qreal(21));
            const QString source = document.toRawText();
            document.setLayoutEnabled(false);
            QTextCursor transaction(&document); transaction.beginEditBlock();
            SemanticFigure::reflow(&document);
            transaction.endEditBlock();
            QVariantList descriptions;
            for (const auto &owner : owners) descriptions.append(FlowConstruction::descriptor(owner));
            QVERIFY(LogicalFlow::registerOwners(&document, descriptions));
            document.setLayoutEnabled(true);
            for (int width : {600, 300, 600}) {
                document.setTextWidth(width);
                document.documentLayout()->documentSize();
                QCOMPARE(document.documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
                QCOMPARE(LogicalFlow::position(&document, owners.first().first.position()).status, LogicalFlow::Status::Handled);
                QCOMPARE(document.toRawText(), source);
                QCOMPARE(captionTable->format(), captionTableFormat);
                QVERIFY(nestedFrames.first()->frameFormat().width().type() == QTextLength::FixedLength);
                QVERIFY(document.documentLayout()->frameBoundingRect(outer).isValid());
                QCOMPARE(document.find(QStringLiteral("linked")).selectedText(), QStringLiteral("linked"));
            }
            // A known Ready update changes only owned geometry and keeps all
            // caption/table formats, logical source offsets and links intact.
            QPointer<QTextFrame> imageFrame;
            for (auto *child : outer->childFrames())
                if (SemanticFigure::belongs(child, "image", outer->objectIndex())) imageFrame = child;
            QVERIFY(imageFrame);
            QTextCursor imageCursor = imageFrame->firstCursorPosition();
            imageCursor.setPosition(imageCursor.position() + 1, QTextCursor::KeepAnchor);
            QVERIFY(imageCursor.charFormat().isImageFormat());
            const int imagePosition = imageCursor.selectionStart();
            auto originalFormat = imageCursor.charFormat().toImageFormat();
            const QSizeF placeholderSize = originalFormat.property(SemanticFigure::placeholderSizeProperty).toSizeF();
            MediaPanel::InlineImageAsset disabled{}; disabled.state = MediaPanel::InlineImageState::Disabled;
            disabled.intrinsic = QSizeF(400, 200); // Not authority until Ready.
            auto unavailable = originalFormat;
            QImage placeholderPixels(20, 20, QImage::Format_ARGB32_Premultiplied); placeholderPixels.fill(QColor(0, 80, 160));
            unavailable.setProperty(SemanticFigure::placeholderPixelsProperty, placeholderPixels);
            QVERIFY(!SemanticFigure::applyAsset(unavailable, figure, disabled));
            QCOMPARE(QSizeF(unavailable.width(), unavailable.height()), placeholderSize);
            QVERIFY(!unavailable.hasProperty(SemanticHtml::imageOriginalSizeProperty));
            MediaPanel::InlineImageAsset ready{}; ready.state = MediaPanel::InlineImageState::Ready; ready.intrinsic = QSizeF(400, 200);
            auto revised = LogicalFlow::editFormats(&document, descriptions, document.revision(), [&] {
                auto format = imageCursor.charFormat().toImageFormat();
                QVERIFY(SemanticFigure::applyAsset(format, figure, ready));
                imageCursor.setCharFormat(format); SemanticFigure::reflow(&document);
            });
            QVERIFY(revised);
            QCOMPARE(QSizeF(imageCursor.charFormat().toImageFormat().width(), imageCursor.charFormat().toImageFormat().height()), QSizeF(20, 10));
            document.documentLayout()->documentSize();
            QCOMPARE(document.documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
            QCOMPARE(captionTable->format(), captionTableFormat);
            QCOMPARE(document.toRawText(), source);
            QCOMPARE(imageCursor.charFormat().anchorHref(), originalFormat.anchorHref());
            QImage readyPixels(20, 10, QImage::Format_ARGB32_Premultiplied); readyPixels.fill(QColor(255, 0, 255));
            document.addResource(QTextDocument::ImageResource, QUrl(originalFormat.name()), readyPixels);
            QImage renderedPage(700, 900, QImage::Format_ARGB32_Premultiplied); renderedPage.fill(Qt::white);
            { QPainter pagePainter(&renderedPage); document.drawContents(&pagePainter); }
            int magenta = 0;
            for (int y = 0; y < renderedPage.height(); ++y)
                for (int x = 0; x < renderedPage.width(); ++x)
                    if (renderedPage.pixelColor(x, y) == QColor(255, 0, 255)) ++magenta;
            QVERIFY(magenta > 0); // Controlled resource paint, no provider/network claim.
            QImage unavailablePaint(20, 20, QImage::Format_ARGB32_Premultiplied); unavailablePaint.fill(Qt::transparent);
            { QPainter placeholderPainter(&unavailablePaint);
              handler.drawObject(&placeholderPainter, QRectF(0, 0, 20, 20), &document, imagePosition, unavailable); }
            QCOMPARE(unavailablePaint.pixelColor(10, 10), QColor(0, 80, 160));
            // Same URL has Ready magenta pixels, but this unavailable occurrence
            // still paints its own existing normal placeholder.
            // Source rounding can produce logical height zero. No one-pixel
            // backing or MIME inference may reintroduce a painted/hit plane.
            ready.intrinsic = QSizeF(1000000, 1);
            revised = LogicalFlow::editFormats(&document, descriptions, document.revision(), [&] {
                auto format = imageCursor.charFormat().toImageFormat();
                QVERIFY(SemanticFigure::applyAsset(format, figure, ready));
                imageCursor.setCharFormat(format); SemanticFigure::reflow(&document);
            });
            QVERIFY(revised);
            document.documentLayout()->documentSize();
            QCOMPARE(document.documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
            const auto zero = imageCursor.charFormat().toImageFormat();
            QCOMPARE(zero.height(), qreal(0));
            QCOMPARE(handler.intrinsicSize(&document, imagePosition, zero).height(), qreal(0));
            QImage paint(600, 600, QImage::Format_ARGB32_Premultiplied); paint.fill(Qt::transparent);
            QPainter painter(&paint); handler.drawObject(&painter, QRectF(0, 0, 20, 0), &document, imagePosition, zero); painter.end();
            int paintedPixels = 0;
            for (int y = 0; y < paint.height(); ++y)
                for (int x = 0; x < paint.width(); ++x) paintedPixels += paint.pixelColor(x, y).alpha() != 0;
            QCOMPARE(paintedPixels, 0);
            QCOMPARE(document.toRawText(), source);
            QCOMPARE(captionTable->format(), captionTableFormat);
            QCOMPARE(document.find(QStringLiteral("linked")).charFormat().anchorHref(), QStringLiteral("wikidict:dog"));
        }
    }

    void figureCaptionZeroContextAndPhysicalAlignmentSurviveImport() {
        QTextDocument document;
        document.setDefaultFont(QFont(QStringLiteral("DejaVu Sans"), 18));
        QTextCursor cursor(&document);
        QTextFrameFormat frameFormat; frameFormat.setWidth(180); frameFormat.setMargin(0);
        QPointer<QTextFrame> frame = cursor.insertFrame(frameFormat);
        const QString explicitChild = SemanticHtml::scaledText(QStringLiteral("Positive"), 1, {},
            SemanticHtml::Basis::NormalBody, 14);
        const QString html = QStringLiteral("<p dir='rtl' style='margin:0'>Zero</p><p dir='rtl' style='margin:0'>%1</p>").arg(explicitChild);
        SemanticFigure::insertHtml(frame->firstCursorPosition(), html, 0, Qt::AlignLeft | Qt::AlignAbsolute,
            nullptr, 18);
        const auto zero = document.find(QStringLiteral("Zero")); QVERIFY(!zero.isNull());
        const auto positive = document.find(QStringLiteral("Positive")); QVERIFY(!positive.isNull());
        QVERIFY(zero.charFormat().property(QTextFormat::FontFamilies).toStringList().contains(SemanticHtml::zeroFontFamilyName));
        QCOMPARE(positive.charFormat().fontPointSize(), qreal(14));
        QVERIFY(!positive.charFormat().property(QTextFormat::FontFamilies).toStringList().contains(SemanticHtml::zeroFontFamilyName));
        QCOMPARE(zero.blockFormat().lineHeight(), qreal(18));
        QCOMPARE(zero.blockFormat().lineHeightType(), int(QTextBlockFormat::MinimumHeight));
        for (int width : {360, 220, 360}) {
            document.setTextWidth(width); document.documentLayout()->documentSize();
            QCOMPARE(zero.blockFormat().layoutDirection(), Qt::RightToLeft);
            QVERIFY(zero.blockFormat().alignment().testFlag(Qt::AlignAbsolute));
            QVERIFY(zero.blockFormat().alignment().testFlag(Qt::AlignLeft));
            QVERIFY(zero.block().layout()->lineCount() > 0);
            QCOMPARE(zero.selectedText(), QStringLiteral("Zero"));
            QCOMPARE(positive.selectedText(), QStringLiteral("Positive"));
        }
        // This public fragment helper also rejects replacement outside the
        // caller's usual edit batch, before later block/character mutations.
        QTextDocument replaced;
        QTextCursor replacementCursor(&replaced);
        QPointer<QTextFrame> doomed = replacementCursor.insertFrame(frameFormat);
        bool once = false;
        connect(&replaced, &QTextDocument::contentsChanged, &replaced, [&] {
            if (once) return;
            once = true; replaced.setPlainText(QStringLiteral("Replacement remains"));
        });
        QVERIFY_EXCEPTION_THROWN(SemanticFigure::insertHtml(doomed->firstCursorPosition(), QStringLiteral("Old caption"),
            12, Qt::AlignLeft | Qt::AlignAbsolute), std::runtime_error);
        QVERIFY(once); QVERIFY(!doomed);
        QCOMPARE(replaced.toPlainText(), QStringLiteral("Replacement remains"));
    }

    void paragraphProjectionRetainsNativeBoundariesAndSeparatePadding() {
        struct Fixture {
            QTextDocument document;
            QVector<FlowConstruction::Owner> owners;
            QVariantList descriptors;
            QString raw;
            QVector<QTextCharFormat> characters;
            QSizeF size;
        };
        const auto edges = [](double top, double right, double bottom, double left) {
            const auto value = [](double n) { return QJsonObject{{"unit", "px"}, {"value", n}}; };
            return QJsonObject{{"top", value(top)}, {"right", value(right)},
                {"bottom", value(bottom)}, {"left", value(left)}};
        };
        const auto make = [&](const QString &shell, const QJsonObject &style, bool project,
                              const QStringList &texts = QStringList{QStringLiteral("Alpha"), QStringLiteral("Beta")}) {
            auto fixture = std::make_unique<Fixture>();
            auto &document = fixture->document;
            document.setDefaultFont(QFont(QStringLiteral("DejaVu Sans"), 12));
            document.setDocumentMargin(4);
            FlowConstruction::RenderContext context;
            context.language = QStringLiteral("en"); context.pointSize = 12;
            context.normalBodyEm = 16; context.legacyVerticalScale = 1;
            QString html = shell;
            for (int i = 0; i < texts.size(); ++i) {
                const QJsonObject span{{"kind", "text"}, {"text", texts[i]}};
                QJsonObject block{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""},
                    {"spans", QJsonArray{span}}};
                if (i == 0 && !style.isEmpty()) block.insert("style", style);
                FlowConstruction::Rendered rendered;
                rendered.html = SemanticHtml::scaledText(texts[i].toHtmlEscaped(), 1, {},
                    SemanticHtml::Basis::Context, 0, false, false, false, 0, QJsonValue(), true, i + 1);
                rendered.parts = QJsonArray{QJsonObject{{"kind", "inline"}, {"run", i + 1}}};
                html.replace(QStringLiteral("{{%1}}").arg(i), FlowConstruction::placeholder(block, rendered, context));
            }
            document.setLayoutEnabled(false);
            document.setHtml(html);
            fixture->owners = FlowConstruction::expand(&document);
            CompiledContent::require(fixture->owners.size() == texts.size());
            fixture->raw = document.toRawText();
            for (int p = 0; p < document.characterCount() - 1; ++p) {
                QTextCursor cursor(&document); cursor.setPosition(p);
                cursor.setPosition(p + 1, QTextCursor::KeepAnchor);
                fixture->characters.append(cursor.charFormat());
            }
            if (project) CompiledContent::require(ParagraphProjection::project(&document, fixture->owners));
            for (const auto &owner : fixture->owners) fixture->descriptors.append(FlowConstruction::descriptor(owner));
            CompiledContent::require(LogicalFlow::registerOwners(&document, fixture->descriptors));
            document.setLayoutEnabled(true); document.setTextWidth(600);
            fixture->size = document.documentLayout()->documentSize();
            return fixture;
        };
        const auto verify = [&](Fixture &f) {
            QVERIFY(f.size.isValid());
            QCOMPARE(f.document.documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
            QCOMPARE(f.document.toRawText(), f.raw);
            QCOMPARE(f.document.characterCount() - 1, f.characters.size());
            for (int p = 0; p < f.characters.size(); ++p) {
                QTextCursor cursor(&f.document); cursor.setPosition(p); cursor.setPosition(p + 1, QTextCursor::KeepAnchor);
                QCOMPARE(cursor.charFormat(), f.characters[p]);
            }
            for (const auto &owner : f.owners) {
                const auto position = LogicalFlow::position(&f.document, owner.first.position());
                QCOMPARE(position.status, LogicalFlow::Status::Handled); QCOMPARE(position.error, 0);
            }
        };
        const auto rect = [](Fixture &f, int owner) {
            return LogicalFlow::position(&f.document, f.owners[owner].first.position())
                .values.value(QStringLiteral("cursorRect")).toRectF();
        };
        const QString first = QStringLiteral("<p style='margin:0;margin-top:7px;margin-bottom:11px'>{{0}}</p>");
        const QString second = QStringLiteral("<p style='margin:0;margin-top:7px;margin-bottom:9px'>{{1}}</p>");
        const QJsonObject padding{{"padding", edges(2, 5, 3, 4)}};
        const QJsonObject authored{{"margins", edges(4, 0, 6, 0)}};
        const QJsonObject zero{{"margins", edges(0, 0, 0, 0)}};
        auto baseline = make(first + second, {}, false);
        auto same = make(first + second, {}, true);
        auto padded = make(first + second, padding, true);
        auto explicitEdges = make(first + second, authored, true);
        auto cleared = make(first + second, zero, true);
        for (auto *f : {baseline.get(), same.get(), padded.get(), explicitEdges.get(), cleared.get()}) verify(*f);
        QCOMPARE(same->size, baseline->size);
        QCOMPARE(rect(*same, 0), rect(*baseline, 0)); QCOMPARE(rect(*same, 1), rect(*baseline, 1));
        QCOMPARE(rect(*padded, 0).top() - rect(*baseline, 0).top(), qreal(2));
        QCOMPARE(rect(*padded, 0).left() - rect(*baseline, 0).left(), qreal(4));
        QCOMPARE(rect(*padded, 1).top() - rect(*baseline, 1).top(), qreal(5));
        QCOMPARE(padded->size.height() - baseline->size.height(), qreal(5));
        QCOMPARE(rect(*explicitEdges, 0).top() - rect(*baseline, 0).top(), qreal(4));
        QCOMPARE(rect(*explicitEdges, 1).top(), rect(*baseline, 1).top());
        QCOMPARE(rect(*cleared, 1).top() - rect(*baseline, 1).top(), qreal(-4));

        // A real unowned heading retains its own stock max contribution. Null
        // margins do not turn the old 11px max into 11+3; explicit margins add.
        const QString heading = QStringLiteral("<h3 style='margin:0;margin-top:3px;margin-bottom:5px'>Heading</h3>");
        auto beforeHeading = make(first + heading, {}, false, {QStringLiteral("Alpha")});
        auto headingNull = make(first + heading, padding, true, {QStringLiteral("Alpha")});
        auto headingExplicit = make(first + heading, authored, true, {QStringLiteral("Alpha")});
        verify(*beforeHeading); verify(*headingNull); verify(*headingExplicit);
        const auto headingY = [](Fixture &f) {
            return f.document.documentLayout()->blockBoundingRect(f.document.find(QStringLiteral("Heading")).block()).top();
        };
        QCOMPARE(headingY(*headingNull) - headingY(*beforeHeading), qreal(5));
        QCOMPARE(headingY(*headingExplicit) - headingY(*beforeHeading), qreal(2));
        auto afterHeading = make(heading + first, {}, false, {QStringLiteral("Alpha")});
        auto afterHeadingNull = make(heading + first, padding, true, {QStringLiteral("Alpha")});
        verify(*afterHeading); verify(*afterHeadingNull);
        QCOMPARE(rect(*afterHeadingNull, 0).top() - rect(*afterHeading, 0).top(), qreal(2));

        const QString table = QStringLiteral("<table style='margin:0' width='120'><tr><td>Cell</td></tr></table>");
        const auto firstTable = [](Fixture &f) {
            for (auto *frame : f.document.rootFrame()->childFrames())
                if (auto *table = qobject_cast<QTextTable *>(frame)) return table;
            return static_cast<QTextTable *>(nullptr);
        };
        for (const bool spacer : {false, true}) {
            const QString middle = spacer
                ? QStringLiteral("<p style='-qt-paragraph-type:empty;margin:0;margin-top:3px'></p>") : QString();
            auto control = make(first + middle + table, {}, false, {QStringLiteral("Alpha")});
            auto nullEdges = make(first + middle + table, padding, true, {QStringLiteral("Alpha")});
            auto authoredEdges = make(first + middle + table, authored, true, {QStringLiteral("Alpha")});
            auto *controlTable = firstTable(*control); QVERIFY(controlTable);
            auto *nullTable = firstTable(*nullEdges); QVERIFY(nullTable);
            auto *authoredTable = firstTable(*authoredEdges); QVERIFY(authoredTable);
            QTextCursor before(controlTable->document()); before.setPosition(controlTable->firstPosition() - 1);
            QCOMPARE(before.block().length() == 1, spacer);
            if (spacer) QCOMPARE(controlTable->firstPosition(), before.block().position() + 1);
            verify(*control); verify(*nullEdges); verify(*authoredEdges);
            const auto geometry = [](QTextTable *value) { return value->document()->documentLayout()->frameBoundingRect(value); };
            QCOMPARE(geometry(nullTable).top() - geometry(controlTable).top(), qreal(5));
            QCOMPARE(geometry(authoredTable).top() - geometry(controlTable).top(), spacer ? qreal(2) : qreal(10));
            QCOMPARE(nullTable->format(), controlTable->format());
            QCOMPARE(authoredTable->format(), controlTable->format());
        }

        // The first owner ends in one cell and the second starts another: this
        // is not paragraph adjacency, even though both report the same frame.
        const QString cells = QStringLiteral("<table style='margin:0'><tr><td>%1</td><td>%2</td></tr></table>").arg(first, second);
        auto cellBaseline = make(cells, {}, false);
        auto cellPadding = make(cells, padding, true);
        verify(*cellBaseline); verify(*cellPadding);
        QCOMPARE(rect(*cellPadding, 0).top() - rect(*cellBaseline, 0).top(), qreal(2));
        QCOMPARE(rect(*cellPadding, 1).top(), rect(*cellBaseline, 1).top());
        QCOMPARE(rect(*cellPadding, 1).left() >= rect(*cellPadding, 0).right(), true);
        QCOMPARE(cellPadding->owners[0].first.blockFormat().doubleProperty(ParagraphProjection::endProperty), qreal(3));

        // Truly empty ordinary content adds no line. Explicit margins remain
        // distinct on both sides of the empty owner; padding never collapses.
        auto emptyZero = make(first, zero, true, {QString()});
        auto emptyPadding = make(first, padding, true, {QString()});
        verify(*emptyZero); verify(*emptyPadding);
        QCOMPARE(emptyZero->document.toRawText(), QString());
        QCOMPARE(emptyZero->size.height(), qreal(8));
        QCOMPARE(emptyPadding->size.height(), qreal(13));
        QCOMPARE(emptyPadding->owners[0].first.blockFormat().boolProperty(ParagraphProjection::emptyProperty), true);
        const QString three = first + second + QStringLiteral("<p style='margin:0;margin-top:6px'>{{2}}</p>");
        auto emptyMiddle = make(three, {}, true, {QStringLiteral("Alpha"), QString(), QStringLiteral("Gamma")});
        verify(*emptyMiddle);
        QCOMPARE(emptyMiddle->owners[1].first.blockFormat().boolProperty(ParagraphProjection::emptyProperty), true);
        QCOMPARE(emptyMiddle->owners[1].first.blockFormat().doubleProperty(ParagraphProjection::startProperty), qreal(11));
        QCOMPARE(emptyMiddle->owners[2].first.blockFormat().doubleProperty(ParagraphProjection::startProperty), qreal(6));

        // Layout uses the original native float exclusion after the owned start
        // moves past it. Resizing never creates a child box or alters source.
        const QString floated = QStringLiteral("<table style='float:left;margin:0' width='100'><tr><td style='padding-bottom:60px'>Float</td></tr></table>");
        const QJsonObject belowFloat{{"padding", edges(160, 8, 0, 5)}};
        auto floating = make(floated + first, belowFloat, true, {QStringLiteral("Alpha Beta Gamma Delta Epsilon")});
        auto *floatTable = firstTable(*floating); QVERIFY(floatTable);
        QCOMPARE(floatTable->frameFormat().position(), QTextFrameFormat::FloatLeft);
        const auto originalFrame = floatTable->frameFormat();
        for (const qreal width : {600., 250., 600.}) {
            floating->document.setTextWidth(width);
            floating->size = floating->document.documentLayout()->documentSize(); verify(*floating);
            const auto glyph = rect(*floating, 0);
            const auto tableRect = floating->document.documentLayout()->frameBoundingRect(floatTable);
            QVERIFY(glyph.top() >= tableRect.bottom());
            QCOMPARE(glyph.left(), qreal(9));
            QCOMPARE(floatTable->frameFormat(), originalFrame);
            QCOMPARE(floating->document.documentLayout()->hitTest(glyph.center(), Qt::FuzzyHit),
                floating->owners[0].first.position());
        }
        // Same-document replacement at edit completion is not an accepted
        // projection, even if the receiver/document objects remain alive.
        auto replacement = make(first, {}, false, {QStringLiteral("Alpha")});
        QVERIFY(LogicalFlow::registerOwners(&replacement->document, {}));
        replacement->document.setLayoutEnabled(false);
        bool replaced = false;
        QObject::connect(&replacement->document, &QTextDocument::contentsChanged, &replacement->document, [&] {
            if (replaced) return;
            replaced = true; replacement->document.setPlainText(QStringLiteral("Replacement survives"));
        });
        QVERIFY(!ParagraphProjection::project(&replacement->document, replacement->owners));
        QVERIFY(replaced); QCOMPARE(replacement->document.toPlainText(), QStringLiteral("Replacement survives"));
    }

    void retainedNorskEntryComposesOrdinaryParagraphsAndTables() {
        // Exact retained Reader JSON from the failed genuine NO GUI import.
        // This is a consumer regression; it does not rerun the producer or FFI.
        QFile input(qEnvironmentVariable("WIKIDICT_NO134_READER_JSON"));
        QVERIFY2(input.open(QIODevice::ReadOnly), "The retained NO134 Reader fixture is required.");
        const QByteArray bytes = input.readAll();
        QCOMPARE(QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex(),
            QByteArrayLiteral("31385b056efca5526003180245d4d38b8050334a1e46f3c411670a332e268ecf"));
        QJsonParseError error;
        const auto response = QJsonDocument::fromJson(bytes, &error);
        QCOMPARE(error.error, QJsonParseError::NoError);
        QVERIFY(response.isObject());
        const auto entries = response.object().value(QStringLiteral("entries")).toArray();
        QCOMPARE(entries.size(), 1);
        const auto entry = entries.first().toObject();
        QCOMPARE(entry.value(QStringLiteral("title")).toString(), QStringLiteral("bibringe"));
        QCOMPARE(entry.value(QStringLiteral("language")).toString(), QStringLiteral("norsk"));
        QCOMPARE(entry.value(QStringLiteral("sections")).toArray().size(), 9);
        const QVariant oldImages = QSettings().value(QStringLiteral("media/allowImages"));
        QSettings().setValue(QStringLiteral("media/allowImages"), false);
        const auto restoreImages = qScopeGuard([&] {
            if (oldImages.isValid()) QSettings().setValue(QStringLiteral("media/allowImages"), oldImages);
            else QSettings().remove(QStringLiteral("media/allowImages"));
        });
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(900, 700); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 120000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.renderResponse(bytes, false));
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(QJsonDocument::fromJson(window.currentJson_), response);
        QVERIFY(!window.readingUncommitted_);
        auto *reader = window.reading_;
        reader->setFocus(Qt::OtherFocusReason);
        QTRY_VERIFY(reader->isVisible() && reader->hasFocus());
        auto *document = reader->document();
        QVERIFY(document->isLayoutEnabled());
        QVERIFY(!window.readingLogicalOwners_.isEmpty());
        const QString source = document->toRawText();
        QVERIFY(source.contains(QStringLiteral("Substantiv")));
        QVERIFY(source.contains(QStringLiteral("Verb")));
        QVERIFY(!source.contains(QStringLiteral("wikidict-flow:")));
        QVERIFY(!source.contains(QStringLiteral("This entry could not be displayed.")));
        int tableCount = 0;
        const auto countTables = [&](auto &&visit, QTextFrame *frame) -> void {
            for (auto *child : frame->childFrames()) {
                if (qobject_cast<QTextTable *>(child)) ++tableCount;
                visit(visit, child);
            }
        };
        countTables(countTables, document->rootFrame());
        QCOMPARE(tableCount, 4);
        const QString stem = QDir(QStringLiteral(".tmp/ui-screenshots")).absoluteFilePath(
            QStringLiteral("norsk-retained-%1").arg(QCoreApplication::applicationPid()));
        QVERIFY(QDir().mkpath(QFileInfo(stem).absolutePath()));
        for (int width : {900, 640, 900}) {
            window.resize(width, 700); QTRY_COMPARE(window.width(), width);
            QTRY_VERIFY(reader->isVisible() && reader->hasFocus());
            if (width == 640) {
                QTRY_VERIFY(!window.searchPane_->isVisible());
                QTRY_COMPARE(window.readerContent_->geometry(), window.readerSplit_->contentsRect());
            } else QTRY_VERIFY(window.searchPane_->isVisible());
            document->documentLayout()->documentSize();
            QCOMPARE(document->documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
            QCOMPARE(document->toRawText(), source);
            QCOMPARE(window.readingLogicalRevision_, document->revision());
            QCOMPARE(window.currentEntry_, entry);
            QVERIFY(window.grab().save(stem + QStringLiteral("-%1.png").arg(width)));
        }

        // GUI03 recovered the same decoded NO body after a missing query, but
        // composition refused it. Reuse that real body on the same document.
        // The fixture API contains cat/dog, not bibringe: the recovery handoff
        // below is explicitly decoder-independent, not an FFI179 lookup claim.
        QTest::keyClick(reader, Qt::Key_Home, Qt::ControlModifier);
        for (int page = 0; page < 3; ++page) QTest::keyClick(reader, Qt::Key_PageDown);
        QTest::keyClick(reader, Qt::Key_End, Qt::ControlModifier);
        window.resize(640, 600); QTRY_COMPARE(window.size(), QSize(640, 600));
        reader->setFocus(Qt::OtherFocusReason);
        QTRY_VERIFY(reader->isVisible() && reader->hasFocus());
        QTest::keyClick(reader, Qt::Key_Home, Qt::ControlModifier);
        for (int page = 0; page < 3; ++page) QTest::keyClick(reader, Qt::Key_PageDown);
        reader->horizontalScrollBar()->setValue(reader->horizontalScrollBar()->maximum());
        reader->verticalScrollBar()->setValue(qRound(reader->verticalScrollBar()->maximum() * .8));
        reader->horizontalScrollBar()->setValue(0);
        QTest::keyClick(reader, Qt::Key_L, Qt::ControlModifier);
        QTRY_VERIFY(window.search_->hasFocus());
        bool historyOpened = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = window.findChild<QDialog *>(QStringLiteral("learningDialog"));
            if (!dialog) return;
            historyOpened = true;
            dialog->reject();
        });
        window.showLearningDialog(0);
        QVERIFY(historyOpened);
        // The offscreen plugin has no compositor to reactivate the parent
        // when its modal child hides; use the established modal-test setup.
        if (QGuiApplication::platformName() == QStringLiteral("offscreen") && !window.isActiveWindow())
            QTimer::singleShot(0, &window, [&window] { window.activateWindow(); });
        QTRY_VERIFY(window.isActiveWindow());
        window.readingPaneAction_->trigger();
        QTRY_VERIFY(reader->isVisible() && reader->hasFocus());
        QCOMPARE(document->toRawText(), source);
        const auto ownersBeforeMissing = window.readingLogicalOwners_;
        const int revisionBeforeMissing = document->revision();
        const auto links = [](QTextDocument *doc) {
            QStringList result;
            for (auto block = doc->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const auto fragment = it.fragment();
                    if (fragment.isValid() && fragment.charFormat().isAnchor())
                        result.append(QString::number(fragment.position()) + QLatin1Char(':')
                            + fragment.text() + QLatin1Char(':') + fragment.charFormat().anchorHref());
                }
            return result;
        };
        const auto linksBeforeMissing = links(document);
        QVERIFY(!linksBeforeMissing.isEmpty());
        auto *accessible = QAccessible::queryAccessibleInterface(reader);
        QVERIFY(accessible && accessible->textInterface());
        const QString accessibleBody = accessible->textInterface()->text(0, -1);
        QCOMPARE(accessibleBody.size(), 1264);
        QTest::keyClick(reader, Qt::Key_L, Qt::ControlModifier);
        QTRY_VERIFY(window.search_->hasFocus());
        // AT-SPI set_text_contents maps to full QLineEdit text replacement.
        // Exercise its real textChanged/debounce connection, then Return.
        const QString missing = QStringLiteral("wikidict-no134-qa-missing-entry");
        window.search_->setText(missing);
        QTRY_VERIFY(!window.searchTimer_->isActive());
        QCOMPARE(window.resultsQuery_, missing);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QVERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
        QCOMPARE(reader->document(), document);
        QCOMPARE(document->revision(), revisionBeforeMissing);
        QCOMPARE(document->toRawText(), source);
        QCOMPARE(window.readingLogicalOwners_, ownersBeforeMissing);
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(!window.readingUncommitted_);
        QCOMPARE(LogicalFlow::inventory(document), LogicalFlow::Status::Handled);
        QCOMPARE(links(document), linksBeforeMissing);
        QCOMPARE(accessible->textInterface()->text(0, -1), accessibleBody);
        QVERIFY(window.grab().save(stem + QStringLiteral("-recovery-missing.png")));
        window.search_->setText(QStringLiteral("bibringe"));
        QTRY_VERIFY(!window.searchTimer_->isActive());
        QCOMPARE(window.resultsQuery_, QStringLiteral("bibringe"));
        // This is the ordinary successful lookup's next call, supplied with
        // the authenticated JSON because the controlled API lacks this word.
        const bool recovered = window.renderResponse(bytes, true);
        const int recoveredViewportWidth = reader->viewport()->width();
        const qreal recoveredPageWidth = document->pageSize().width();
        QVERIFY(window.grab().save(stem + QStringLiteral("-recovery-result.png")));
        QVERIFY2(recovered, "Same-document NO recovery must compose at the allocated Reading width.");
        QVERIFY(recoveredViewportWidth > 0);
        QVERIFY(recoveredPageWidth > 0);
        QCOMPARE(reader->document(), document);
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(QJsonDocument::fromJson(window.currentJson_), response);
        QVERIFY(!window.readingUncommitted_);
        QVERIFY(document->isLayoutEnabled());
        QCOMPARE(document->toRawText(), source);
        QCOMPARE(window.readingLogicalRevision_, document->revision());
        QVERIFY(!window.readingLogicalOwners_.isEmpty());
        QCOMPARE(LogicalFlow::inventory(document), LogicalFlow::Status::Handled);
        QCOMPARE(links(document), linksBeforeMissing);
        QCOMPARE(accessible->textInterface()->text(0, -1), accessibleBody);
        tableCount = 0; countTables(countTables, document->rootFrame());
        QCOMPARE(tableCount, 4);
        QCOMPARE(document->documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
    }

    void compiledReadingComposesParagraphsCaptionsAndFormatUpdates() {
        // Controlled final-model JSON through the ordinary Reading composition.
        // Native producer interoperability and platform AT transport are separate.
        MainWindow window{QString()};
        window.resize(900, 640); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        auto *browser = window.reading_;
        window.activateWindow(); browser->setFocus(Qt::OtherFocusReason);
        QTRY_VERIFY(browser->isVisible() && browser->hasFocus());
        const auto length = [](qreal value) { return QJsonObject{{"unit", "px"}, {"value", value}}; };
        const auto edges = [&](qreal top, qreal right, qreal bottom, qreal left) {
            return QJsonObject{{"top", length(top)}, {"right", length(right)}, {"bottom", length(bottom)}, {"left", length(left)}};
        };
        const auto span = [](QString text) { return QJsonObject{{"kind", "text"}, {"text", text}}; };
        const auto paragraph = [&](QString text) {
            return QJsonObject{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", QJsonArray{span(text)}}};
        };
        const auto inlinePart = [&](QString text) {
            return QJsonObject{{"kind", "inline"}, {"spans", QJsonArray{span(text)}}};
        };
        const QJsonObject image{{"file", "Controlled composition.png"}, {"width_px", 96},
            {"height_px", QJsonValue()}, {"alt", "Explicit placeholder"}, {"tooltip", "Raw <b>image</b> advice"}};
        auto captionLink = span(QStringLiteral("Caption linked text"));
        captionLink.insert("kind", "link");
        captionLink.insert("target", "dog");
        auto caption = paragraph({}); caption.insert("spans", QJsonArray{captionLink});
        auto figure = QJsonObject{{"image_span", QJsonObject{{"kind", "text"}, {"text", ""}, {"image", image}}},
            {"format", "thumbnail"}, {"sizing", "requested_fit"}, {"placement", "float_left"}, {"clear", "none"},
            {"margins", edges(2, 3, 4, 5)}, {"image_insets", edges(1, 2, 3, 4)},
            {"caption_padding", edges(2, 4, 3, 5)}, {"caption_font_scale", .884}, {"caption_line_height", length(18)},
            {"frame_background", QJsonObject{{"kind", "transparent"}}}, {"frame_border", QJsonObject{{"kind", "none"}}},
            {"image_background", QJsonObject{{"kind", "transparent"}}}, {"image_border", QJsonObject{{"kind", "none"}}},
            {"caption_foreground", QJsonObject{{"kind", "rgb"}, {"value", "#154360"}}},
            {"caption_background", QJsonObject{{"kind", "transparent"}}}, {"caption", QJsonArray{}},
            {"caption_blocks", QJsonArray{caption, paragraph(QStringLiteral("Caption second paragraph"))}},
            {"caption_text_align", "right"}};
        for (const QString &placement : {QStringLiteral("none"), QStringLiteral("center"), QStringLiteral("float_left"), QStringLiteral("float_right")}) {
            browser->setLayoutDirection(placement == QStringLiteral("float_right") ? Qt::RightToLeft : Qt::LeftToRight);
            figure.insert("placement", placement);
            auto owner = paragraph({}); owner.insert("spans", QJsonArray{});
            owner.insert("style", QJsonObject{{"margins", edges(7, 9, 11, 13)}, {"padding", edges(3, 5, 4, 6)}});
            const QJsonObject scope{{"mode", "isolate"}, {"authored_direction", "rtl"}, {"resolved_direction", "rtl"},
                {"language", "he"}, {"parts", QJsonArray{inlinePart(QStringLiteral(" \u05d3\u05d4\u05d5"))}}};
            owner.insert("flow", QJsonArray{inlinePart(QStringLiteral("Parent prefix AV A\u0301 ")),
                QJsonObject{{"kind", "figure"}, {"spans", QJsonArray{}}, {"figure", figure}},
                inlinePart(QStringLiteral(" parent suffix \u05d0\u05d1\u05d2 followed by words that wrap at a narrow reading width")),
                QJsonObject{{"kind", "scope"}, {"spans", QJsonArray{}}, {"scope", scope}}});
            auto detail = paragraph({}); detail.insert("kind", "list_detail"); detail.insert("depth", 2);
            detail.insert("spans", QJsonArray{});
            detail.insert("flow", QJsonArray{inlinePart(QStringLiteral("\u2029Raw first\u2029\u2029Raw last\u2029"))});
            auto cellOwner = paragraph({}); cellOwner.insert("spans", QJsonArray{});
            cellOwner.insert("flow", QJsonArray{inlinePart(QStringLiteral("Cell before ")),
                QJsonObject{{"kind", "figure"}, {"spans", QJsonArray{}}, {"figure", figure}}, inlinePart(QStringLiteral(" Cell after"))});
            const QJsonArray cells{QJsonObject{{"spans", QJsonArray{span(QStringLiteral("First cell"))}}},
                QJsonObject{{"spans", QJsonArray{}}, {"blocks", QJsonArray{cellOwner}}}};
            const QJsonObject table{{"kind", "table"}, {"spans", QJsonArray{}},
                {"table", QJsonObject{{"rows", QJsonArray{QJsonObject{{"cells", cells}}}}}}};
            const QJsonObject entry{{"title", "Controlled final flow"}, {"language", "English"}, {"language_code", "en"},
                {"kind", "language"}, {"sections", QJsonArray{QJsonObject{{"title", "Controlled"}, {"level", 2},
                    {"blocks", QJsonArray{paragraph(QStringLiteral("Ordinary predecessor")), owner, detail, table,
                        paragraph(QStringLiteral("Ordinary successor"))}}}}}, {"references", QJsonArray{}}, {"media", QJsonArray{}}};
            window.currentEntry_ = entry;
            window.media_->setEntry(entry);
            QVERIFY(window.refreshReading());
            auto *document = browser->document();
            auto *layout = document->documentLayout();
            QTRY_VERIFY(window.readingLogicalDocument_ == document && !window.readingLogicalOwners_.isEmpty());
            QTRY_COMPARE(window.readingLogicalRevision_, document->revision());
            const QString source = document->toRawText();
            QTextCursor initialSelection(document); initialSelection.select(QTextCursor::Document);
            const QString selectedSource = initialSelection.selectedText();
            const auto before = document->find(QStringLiteral("Parent prefix")); QVERIFY(!before.isNull());
            const auto after = document->find(QStringLiteral("parent suffix")); QVERIFY(!after.isNull());
            const auto rawFirst = document->find(QStringLiteral("Raw first")); QVERIFY(!rawFirst.isNull());
            const auto rawLast = document->find(QStringLiteral("Raw last")); QVERIFY(!rawLast.isNull());
            QCOMPARE(rawFirst.blockFormat().leftMargin(), rawLast.blockFormat().leftMargin());
            QCOMPARE(rawFirst.blockFormat().leftMargin(), qreal(46));
            QVERIFY(rawFirst.block().previous().text().isEmpty());
            QVERIFY(rawFirst.block().next().text().isEmpty());
            QVERIFY(rawLast.block().next().text().isEmpty());
            const auto cellText = document->find(QStringLiteral("Cell before")); QVERIFY(!cellText.isNull());
            QVERIFY(cellText.currentTable());
            QVERIFY(cellText.currentTable()->cellAt(cellText).column() > 0);
            QCOMPARE(document->toPlainText().count(QStringLiteral("Parent prefix")), 1);
            QCOMPARE(document->toPlainText().count(QStringLiteral("Caption linked text")), 2);
            QVERIFY(!document->toPlainText().contains(QStringLiteral("wikidict-flow:")));
            QVERIFY(!document->toPlainText().contains(QStringLiteral("wikidict-figure:")));
            QVector<QTextCursor> images;
            for (auto block = document->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const auto fragment = it.fragment();
                    if (!fragment.isValid() || !fragment.charFormat().hasProperty(SemanticHtml::figureImageProperty)) continue;
                    QTextCursor cursor(document); cursor.setPosition(fragment.position());
                    cursor.setPosition(fragment.position() + 1, QTextCursor::KeepAnchor); images.append(cursor);
                    QVERIFY(!fragment.charFormat().property(SemanticFigure::placeholderPixelsProperty).value<QImage>().isNull());
                    QVERIFY(!fragment.charFormat().boolProperty(SemanticFigure::sizingReadyProperty));
                }
            QCOMPARE(images.size(), 2);
            layout->documentSize();
            const auto missingCatalogueReady = [&] {
                for (const auto &cursor : images)
                    if (cursor.charFormat().intProperty(SemanticHtml::inlineImageStateProperty)
                        != int(MediaPanel::InlineImageState::Error)) return false;
                return window.readingLogicalRevision_ == document->revision();
            };
            QTRY_VERIFY_WITH_TIMEOUT(missingCatalogueReady(), 5000);
            const auto verify = [&] {
                layout->documentSize();
                if (layout->property("_wikidictParagraphBoxLayoutError").toInt() != 0) return false;
                for (int position : {before.selectionStart(), after.selectionStart(), cellText.selectionStart()})
                    if (LogicalFlow::position(document, position).status != LogicalFlow::Status::Handled) return false;
                return document->toRawText() == source && window.currentEntry_ == entry
                    && window.readingLogicalRevision_ == document->revision();
            };
            for (int width : {900, 640, 900}) {
                window.resize(width, 640); QTRY_COMPARE(window.width(), width);
                QTRY_VERIFY(browser->isVisible() && browser->viewport()->isVisible() && browser->hasFocus());
                QVERIFY(verify());
                auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible);
                auto *text = accessible->textInterface(); QVERIFY(text);
                int first = -1, last = -1;
                const QString parentLine = text->textAtOffset(before.selectionStart() + 2, QAccessible::LineBoundary, &first, &last);
                QVERIFY(first <= before.selectionStart() + 2 && last > before.selectionStart() + 2);
                QVERIFY(!parentLine.contains(QStringLiteral("Caption")));
                const auto captionText = document->find(QStringLiteral("Caption linked text"));
                QVERIFY(!captionText.isNull() && !captionText.charFormat().anchorHref().isEmpty());
                const auto captionLine = text->textAtOffset(captionText.selectionStart() + 2, QAccessible::LineBoundary, &first, &last);
                QVERIFY(captionLine.contains(QStringLiteral("Caption")));
                QTextCursor all(document); all.select(QTextCursor::Document);
                QCOMPARE(all.selectedText(), selectedSource);
            }
            const auto descriptors = window.readingLogicalOwners_;
            MediaPanel::InlineImageAsset ready{}; ready.state = MediaPanel::InlineImageState::Ready; ready.intrinsic = QSizeF(400, 200);
            QVERIFY(window.editDocumentFormats(browser, [&] {
                QImage pixels(96, 48, QImage::Format_ARGB32_Premultiplied); pixels.fill(QColor(210, 45, 125));
                for (auto cursor : images) {
                    auto format = cursor.charFormat().toImageFormat();
                    QVERIFY(SemanticFigure::applyAsset(format, figure, ready));
                    format.setProperty(SemanticHtml::inlineImageStateProperty, int(ready.state));
                    format.setProperty(SemanticHtml::inlineImageStatusProperty, QString());
                    document->addResource(QTextDocument::ImageResource, QUrl(format.name()), pixels);
                    cursor.setCharFormat(format);
                }
                SemanticFigure::reflow(document);
            }));
            QCOMPARE(window.readingLogicalOwners_, descriptors);
            for (const auto &cursor : images) {
                const auto format = cursor.charFormat().toImageFormat();
                QCOMPARE(QSizeF(format.width(), format.height()), QSizeF(96, 48));
                QVERIFY(format.boolProperty(SemanticFigure::sizingReadyProperty));
            }
            QVERIFY(verify());
            QTextCursor imageCursor = images.first();
            imageCursor.setPosition(imageCursor.selectionStart()); browser->setTextCursor(imageCursor); browser->ensureCursorVisible();
            const QString frame = QStringLiteral(".tmp/ui-screenshots/composed-flow-%1-%2.png")
                .arg(QCoreApplication::applicationPid()).arg(placement);
            QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")); QVERIFY(window.grab().save(frame));
        }
    }

    void readingCompositionRejectsReplacementBeforeRegistration() {
        MainWindow window{QString()};
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        auto *browser = window.reading_;
        QPointer<QTextDocument> document(browser->document());
        const QJsonObject span{{"kind", "text"}, {"text", "Original controlled owner"}};
        const QJsonObject owner{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", QJsonArray{}},
            {"flow", QJsonArray{QJsonObject{{"kind", "inline"}, {"spans", QJsonArray{span}}}}}};
        window.currentEntry_ = QJsonObject{{"title", "Controlled replacement"}, {"language", "English"},
            {"language_code", "en"}, {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2},
                {"blocks", QJsonArray{owner}}}}}};
        bool replaced = false;
        QString replacement;
        const auto connection = connect(document, &QTextDocument::contentsChanged, &window, [&] {
            if (replaced || !document) return;
            bool expanded = false;
            for (auto block = document->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const auto fragment = it.fragment();
                    expanded |= fragment.isValid() && fragment.charFormat().hasProperty(SemanticHtml::sourceRunProperty)
                        && fragment.text().contains(QStringLiteral("Original controlled owner"));
                }
            if (!expanded) return;
            replaced = true;
            replacement = QString(document->characterCount() - 1, QChar('R'));
            document->setPlainText(replacement);
        });
        const auto disconnectReplacement = qScopeGuard([&] { disconnect(connection); });
        const bool refused = !window.refreshReading();
        QVERIFY(replaced); QVERIFY(refused); QVERIFY(document);
        QCOMPARE(document->toPlainText(), replacement);
        QVERIFY(window.readingLogicalOwners_.isEmpty());
        QCOMPARE(LogicalFlow::inventory(document), LogicalFlow::Status::Stock);
        QVERIFY(!document->isLayoutEnabled()); // Unknown replacement stays unexposed until explicit recomposition.
        QCOMPARE(window.statusBar()->currentMessage(), QStringLiteral("This entry could not be displayed. Your dictionary data is unchanged. Choose another entry or language."));
        QVERIFY(window.clearReadingProjection());
        disconnect(connection);
        QVERIFY(window.refreshReading());
        QVERIFY(document->isLayoutEnabled());
        QVERIFY(window.readingLogicalDocument_ == document && !window.readingLogicalOwners_.isEmpty());
        document->documentLayout()->documentSize();
        QCOMPARE(document->documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
        QVERIFY(document->toPlainText().contains(QStringLiteral("Original controlled owner")));
        QVERIFY(window.clearReadingProjection());
        browser->setHtml(QStringLiteral("<p>No dictionaries are installed yet.</p>"));
        document->documentLayout()->documentSize();
        QCOMPARE(LogicalFlow::inventory(document), LogicalFlow::Status::Stock);
        QVERIFY(window.readingLogicalOwners_.isEmpty());
        QVERIFY(!document->toPlainText().contains(QStringLiteral("Original controlled owner")));
    }

    void readingImageCallbackUpdatesEveryMergedOccurrence() {
        MainWindow window{QString()}; window.resize(900, 640); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        const QJsonObject image{{"file", "Missing merged image.png"}, {"alt", "Same authored alternative"}};
        const QJsonObject imageSpan{{"kind", "text"}, {"text", ""}, {"image", image}};
        const QJsonObject paragraph{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""},
            {"spans", QJsonArray{imageSpan, imageSpan}}};
        const QJsonObject entry{{"title", "Merged images"}, {"language_code", "en"}, {"media", QJsonArray{}},
            {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2}, {"blocks", QJsonArray{paragraph}}}}}};
        window.media_->setEntry(entry); window.currentEntry_ = entry; QVERIFY(window.refreshReading());
        auto *document = window.reading_->document();
        QVector<int> positions; QTextImageFormat sharedFormat;
        for (auto block = document->begin(); block.isValid(); block = block.next())
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
                const QUrl url(fragment.charFormat().toImageFormat().name());
                if (url.scheme() != SemanticHtml::inlineImageScheme) continue;
                if (positions.isEmpty()) sharedFormat = fragment.charFormat().toImageFormat();
                for (int i = 0; i < fragment.length(); ++i) {
                    QCOMPARE(document->characterAt(fragment.position() + i), QChar::ObjectReplacementCharacter);
                    positions.append(fragment.position() + i);
                }
            }
        QCOMPARE(positions.size(), 2);
        // HTML import gives each image its own frame ObjectIndex. Construct the
        // separate ordinary-image case that can really share one text fragment.
        QVERIFY(window.clearReadingProjection());
        ++window.inlineImageGeneration_;
        document->clear();
        sharedFormat.clearProperty(QTextFormat::ObjectIndex);
        sharedFormat.clearProperty(SemanticHtml::sourceRunProperty);
        QTextCursor insert(document);
        insert.insertText(QString(2, QChar::ObjectReplacementCharacter), sharedFormat);
        positions = {0, 1};
        const auto merged = document->begin().begin().fragment();
        QVERIFY(merged.isValid() && merged.charFormat().isImageFormat());
        QCOMPARE(merged.position(), 0); QCOMPARE(merged.length(), 2);
        QVERIFY(window.readingLogicalOwners_.isEmpty());
        const QString source = document->toRawText();
        document->documentLayout()->documentSize();
        const auto complete = [&] {
            for (int position : positions) {
                QTextCursor cursor(document); cursor.setPosition(position); cursor.setPosition(position + 1, QTextCursor::KeepAnchor);
                const auto format = cursor.charFormat();
                if (format.intProperty(SemanticHtml::inlineImageStateProperty) != int(MediaPanel::InlineImageState::Error)
                    || format.stringProperty(SemanticHtml::inlineImageStatusProperty)
                        != QStringLiteral("This image is not in the dictionary's media catalogue.")) return false;
            }
            return window.readingLogicalOwners_.isEmpty() && window.readingLogicalRevision_ == -1;
        };
        QTRY_VERIFY_WITH_TIMEOUT(complete(), 5000);
        QTextCursor first(document), second(document);
        first.setPosition(positions[0]); first.setPosition(positions[0] + 1, QTextCursor::KeepAnchor);
        second.setPosition(positions[1]); second.setPosition(positions[1] + 1, QTextCursor::KeepAnchor);
        QCOMPARE(first.charFormat(), second.charFormat());
        QCOMPARE(document->toRawText(), source); QCOMPARE(window.currentEntry_, entry);
        document->documentLayout()->documentSize();
        QCOMPARE(document->documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
    }

    void readingLiteralSchemeTextDoesNotRequireOwnerMarkers() {
        MainWindow window{QString()};
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        const QString literal = QStringLiteral("Literal wikidict-flow: remains plain text");
        const QJsonObject text{{"kind", "text"}, {"text", literal}};
        const QJsonObject heading{{"kind", "heading"}, {"level", 3}, {"spans", QJsonArray{text}}};
        window.currentEntry_ = QJsonObject{{"title", "Literal scheme"}, {"language_code", "en"},
            {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2}, {"blocks", QJsonArray{heading}}}}}};
        window.refreshReading();
        auto *document = window.reading_->document();
        QVERIFY(document->toPlainText().contains(literal));
        QVERIFY(window.readingLogicalOwners_.isEmpty());
        QCOMPARE(LogicalFlow::inventory(document), LogicalFlow::Status::Stock);
    }

    void readingResetRetainsAReentrantSameDocumentComposition() {
        MainWindow window{QString()}; window.resize(900, 640); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        const auto entry = [](const QString &value) {
            const QJsonObject span{{"kind", "text"}, {"text", value}};
            const QJsonObject block{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", QJsonArray{span}}};
            return QJsonObject{{"title", value}, {"language_code", "en"},
                {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2}, {"blocks", QJsonArray{block}}}}}};
        };
        window.currentEntry_ = entry(QStringLiteral("Original owner")); window.refreshReading();
        QPointer<QTextDocument> document(window.reading_->document());
        auto *layout = document->documentLayout(); layout->documentSize();
        bool reentered = false;
        const auto connection = connect(layout, &QAbstractTextDocumentLayout::update, &window, [&](const QRectF &) {
            if (reentered) return;
            reentered = true;
            window.currentEntry_ = entry(QStringLiteral("New same-document owner"));
            window.refreshReading();
        });
        const auto cleanup = qScopeGuard([&] { disconnect(connection); });
        QVERIFY(!window.clearReadingProjection());
        QVERIFY(reentered); QVERIFY(document && window.reading_->document() == document);
        QCOMPARE(document->toPlainText().count(QStringLiteral("New same-document owner")), 1);
        QVERIFY(!window.readingLogicalOwners_.isEmpty());
        QCOMPARE(window.readingLogicalDocument_.data(), document.data());
        QCOMPARE(window.readingLogicalRevision_, document->revision());
        layout->documentSize();
        QCOMPARE(layout->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
        const auto text = document->find(QStringLiteral("New same-document owner")); QVERIFY(!text.isNull());
        QCOMPARE(LogicalFlow::position(document, text.selectionStart()).status, LogicalFlow::Status::Handled);
    }

    void styledCollapsibleWhitespaceHasNoInventedContentLine() {
        MainWindow window{QString()}; window.resize(900, 640); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        const auto length = [](qreal value) { return QJsonObject{{"unit", "px"}, {"value", value}}; };
        const auto edges = [&](qreal top, qreal bottom) {
            return QJsonObject{{"top", length(top)}, {"right", length(0)}, {"bottom", length(bottom)}, {"left", length(0)}};
        };
        const auto paragraph = [](const QString &text) {
            return QJsonObject{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""},
                {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", text}}}}};
        };
        for (const QString &whitespace : {QString(), QStringLiteral(" "), QStringLiteral("\n\t ")}) {
            qreal withoutPadding = -1;
            for (bool padded : {false, true}) {
                auto empty = paragraph(whitespace);
                empty.insert("style", QJsonObject{{"margins", edges(0, 0)}, {"padding", edges(padded ? 3 : 0, padded ? 4 : 0)}});
                const QJsonObject entry{{"title", "Controlled empty geometry"}, {"language_code", "en"},
                    {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2},
                        {"blocks", QJsonArray{paragraph(QStringLiteral("Before")), empty, paragraph(QStringLiteral("After"))}}}}}};
                window.currentEntry_ = entry; window.refreshReading();
                auto *document = window.reading_->document();
                auto *layout = document->documentLayout(); const QSizeF size = layout->documentSize();
                QCOMPARE(layout->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
                int empties = 0;
                for (const auto &value : window.readingLogicalOwners_) {
                    const auto owner = value.toMap(); const int first = owner.value("first").toInt();
                    if (first != owner.value("last").toInt()) continue;
                    ++empties;
                    const auto block = document->findBlock(first);
                    QVERIFY(block.isValid() && block.text().isEmpty());
                    QVERIFY(block.blockFormat().boolProperty(QTextFormat::UserProperty + 0x5763));
                    QCOMPARE(block.layout()->lineCount(), 0);
                    QCOMPARE(LogicalFlow::position(document, first).status, LogicalFlow::Status::Handled);
                }
                QCOMPARE(empties, 1);
                QCOMPARE(window.currentEntry_, entry);
                if (!padded) withoutPadding = size.height();
                else QCOMPARE(size.height() - withoutPadding, qreal(7));
            }
        }
    }

    void failedReadingPreservesSourceHistoryAndKeyboardRecovery() {
        const QVariant oldImages = QSettings().value(QStringLiteral("media/allowImages"));
        QSettings().setValue(QStringLiteral("media/allowImages"), false);
        const auto restoreImages = qScopeGuard([&] {
            if (oldImages.isValid()) QSettings().setValue(QStringLiteral("media/allowImages"), oldImages);
            else QSettings().remove(QStringLiteral("media/allowImages"));
        });
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(900, 640); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 120000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTRY_VERIFY(window.isActiveWindow());
        const bool oldHistoryEnabled = window.learning_.settings().historyEnabled;
        const int oldHistoryLimit = window.learning_.settings().historyLimit;
        window.learning_.setHistoryEnabled(true); window.learning_.setHistoryLimit(100);
        window.learning_.record(window.savedWord(window.currentEntry_));
        const auto restoreHistorySettings = qScopeGuard([&] {
            window.learning_.setHistoryEnabled(oldHistoryEnabled); window.learning_.setHistoryLimit(oldHistoryLimit);
        });
        auto *reader = window.reading_;
        reader->setFocus(); QTRY_VERIFY(reader->hasFocus());
        QTRY_VERIFY(window.searchPane_->isVisible() && window.readerContent_->isVisible());
        QTRY_COMPARE(window.readerSplit_->sizes().size(), 2);
        QTRY_VERIFY(window.readerSplit_->sizes().at(0) > 0);
        const int wideSidebarWidth = window.readerSplit_->sizes().at(0);
        const auto response = [](const QJsonObject &entry) {
            return QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(QJsonDocument::Compact);
        };
        const auto words = [](const QVector<SavedWord> &items) {
            QJsonArray result;
            for (const auto &word : items) result.append(QJsonObject{
                {"key", word.key}, {"title", word.title}, {"language", word.language}, {"kind", word.kind},
                {"clue", word.clue}, {"originRoot", word.originRoot}, {"originEdition", word.originEdition},
                {"savedAt", word.savedAt}, {"lastViewed", word.lastViewed}, {"views", word.views}});
            return result;
        };
        const auto visits = [&] {
            QJsonArray result;
            for (const auto &visit : window.visits_) {
                auto values = visit.collapsed.values(); std::sort(values.begin(), values.end());
                QJsonArray collapsed; for (int value : values) collapsed.append(value);
                result.append(QJsonObject{{"title", visit.title}, {"language", visit.language}, {"kind", visit.kind},
                    {"scroll", visit.scroll}, {"collapsed", collapsed}, {"position", visit.cursorPosition},
                    {"anchor", visit.cursorAnchor}, {"readerFocused", visit.readerFocused}});
            }
            return result;
        };
        const auto edges = [](const QString &unit, double top) {
            const auto length = [&](double value) { return QJsonObject{{"unit", unit}, {"value", value}}; };
            return QJsonObject{{"top", length(top)}, {"right", length(0)}, {"bottom", length(0)}, {"left", length(0)}};
        };
        const auto paragraph = [&](const QString &text, const QString &unit, double top) {
            return QJsonObject{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""},
                {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", text}}}},
                {"style", QJsonObject{{"padding", edges(unit, top)}}}};
        };
        const QString failure = QStringLiteral("This entry could not be displayed. Your dictionary data is unchanged. Choose another entry or language.");
        const QString missingFile = QStringLiteral("Controlled previous-entry image.png");
        const QJsonObject cat = window.currentEntry_;
        const auto catKey = window.savedWord(cat).key;
        const bool initiallyBookmarked = window.learning_.isBookmarked(catKey);
        if (!initiallyBookmarked) window.learning_.toggleBookmark(window.savedWord(cat));
        const auto restoreBookmark = qScopeGuard([&] {
            if (!initiallyBookmarked && window.learning_.isBookmarked(catKey))
                window.learning_.toggleBookmark(window.savedWord(cat));
        });
        QVERIFY(window.learning_.isBookmarked(catKey));
        QJsonObject failedEntry;
        const QString frameStem = QDir(QStringLiteral(".tmp/ui-screenshots")).absoluteFilePath(
            QStringLiteral("reading-failure-%1").arg(QCoreApplication::applicationPid()));
        QVERIFY(QDir().mkpath(QFileInfo(frameStem).absolutePath()));
        for (int variant = 0; variant < 2; ++variant) {
            if (variant) {
                QVERIFY(window.openWord(QStringLiteral("dog")));
                QCOMPARE(title(window), QStringLiteral("dog"));
                QVERIFY(window.visitIndex_ > 0);
            }
            const QJsonObject good = window.currentEntry_;
            const QString goodTitle = title(window);
            // A passive catalogue entry proves the old media binding really exists.
            auto mediaEntry = good;
            mediaEntry.insert("media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", missingFile}, {"caption", "Old entry media"}}});
            window.media_->setEntry(mediaEntry);
            QCOMPARE(window.media_->requestInlineImage(missingFile, &window, QStringLiteral("old-passive"), {}).state,
                MediaPanel::InlineImageState::Disabled);
            reader->setFocus(); QTRY_VERIFY(reader->hasFocus());
            QTextCursor selected(reader->document()); selected.setPosition(0);
            selected.setPosition(qMin(10, reader->document()->characterCount() - 1), QTextCursor::KeepAnchor);
            reader->setTextCursor(selected); window.saveVisit();
            const int selectedPosition = selected.position(), selectedAnchor = selected.anchor();
            const int priorIndex = window.visitIndex_;
            const auto priorVisits = visits();
            const auto priorHistory = words(window.learning_.history());
            const auto priorBookmarks = words(window.learning_.bookmarks());
            const QVariant priorLastWord = QSettings().value(QStringLiteral("reader/lastWord"));
            const QVariant priorLastKind = QSettings().value(QStringLiteral("reader/lastKind"));
            failedEntry = QJsonObject{{"title", "Controlled unavailable entry"}, {"language", "English"},
                {"language_code", "en"}, {"kind", "language"}, {"media", QJsonArray{}}};
            const QJsonArray blocks = variant == 0
                ? QJsonArray{paragraph(QStringLiteral("Partial content must stay hidden"), QStringLiteral("em"), double(std::numeric_limits<float>::max()))}
                : QJsonArray{paragraph(QStringLiteral("First bounded paragraph"), QStringLiteral("px"), 5000000),
                    paragraph(QStringLiteral("Second bounded paragraph"), QStringLiteral("px"), 5000000)};
            failedEntry.insert("sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2}, {"blocks", blocks}}});
            QVERIFY(!window.renderResponse(response(failedEntry)));
            QCOMPARE(window.currentEntry_, failedEntry);
            QCOMPARE(QJsonDocument::fromJson(window.currentJson_).object().value("entries").toArray().first().toObject(), failedEntry);
            QVERIFY(window.readingUncommitted_); QVERIFY(!window.loading_);
            QCOMPARE(reader->document()->toPlainText(), failure);
            QVERIFY(reader->document()->isLayoutEnabled());
            QVERIFY(window.readingLogicalOwners_.isEmpty());
            QCOMPARE(LogicalFlow::inventory(reader->document()), LogicalFlow::Status::Stock);
            QVERIFY(!window.listen_->isEnabled()); QVERIFY(!window.bookmark_->isEnabled());
            QVERIFY(!window.sections_->isEnabled());
            QCOMPARE(window.bookmark_->text(), QString::fromUtf8("\xe2\x98\x86 Bookmark"));
            const auto stale = window.media_->requestInlineImage(missingFile, &window, QStringLiteral("after-failure"), {});
            QCOMPARE(stale.state, MediaPanel::InlineImageState::Error);
            QCOMPARE(stale.message, QStringLiteral("This image is not in the dictionary's media catalogue."));
            window.saveVisit();
            QCOMPARE(window.visitIndex_, priorIndex); QCOMPARE(visits(), priorVisits);
            QCOMPARE(words(window.learning_.history()), priorHistory);
            QCOMPARE(words(window.learning_.bookmarks()), priorBookmarks);
            QCOMPARE(QSettings().value(QStringLiteral("reader/lastWord")), priorLastWord);
            QCOMPARE(QSettings().value(QStringLiteral("reader/lastKind")), priorLastKind);
            QVERIFY(window.back_->isEnabled());
            if (variant == 0) {
                for (int width : {900, 640}) {
                    reader->setFocus(); window.resize(width, 640);
                    QTRY_COMPARE(window.width(), width);
                    QTRY_VERIFY(reader->isVisible() && reader->viewport()->isVisible());
                    if (width < 720) {
                        QTRY_VERIFY(window.searchPane_->isHidden());
                        QTRY_COMPARE(window.readerContent_->geometry(), window.readerSplit_->contentsRect());
                    } else {
                        QTRY_VERIFY(window.searchPane_->isVisible());
                        QTRY_COMPARE(window.readerSplit_->sizes().at(0), wideSidebarWidth);
                        QTRY_COMPARE(window.readerContent_->geometry().right(), window.readerSplit_->contentsRect().right());
                    }
                    QCOMPARE(reader->document()->toPlainText(), failure);
                    QVERIFY(window.grab().save(frameStem + QStringLiteral("-failed-%1.png").arg(width)));
                }
            }
            reader->setFocus(); QTRY_VERIFY(reader->hasFocus());
            QTest::keyClick(reader, Qt::Key_Left, Qt::AltModifier);
            QTRY_COMPARE(title(window), goodTitle);
            QTRY_VERIFY(!window.readingUncommitted_);
            QCOMPARE(window.visitIndex_, priorIndex);
            QCOMPARE(reader->textCursor().position(), selectedPosition);
            QCOMPARE(reader->textCursor().anchor(), selectedAnchor);
            QVERIFY(window.listen_->isEnabled()); QVERIFY(window.bookmark_->isEnabled());
            QCOMPARE(window.bookmark_->text(), window.learning_.isBookmarked(window.savedWord(window.currentEntry_).key)
                ? QString::fromUtf8("\xe2\x98\x85 Saved") : QString::fromUtf8("\xe2\x98\x86 Bookmark"));
            QVERIFY(window.resultStatus_->text() != failure);
            QVERIFY(window.statusBar()->currentMessage() != failure);
            QCOMPARE(words(window.learning_.bookmarks()), priorBookmarks);
            if (variant) {
                QTest::keyClick(reader, Qt::Key_Left, Qt::AltModifier);
                QTRY_COMPARE(title(window), QStringLiteral("cat"));
                QCOMPARE(window.visitIndex_, priorIndex - 1);
            }
        }
        // Search and language remain keyboard reachable from the failed Reading pane.
        QVERIFY(!window.renderResponse(response(failedEntry)));
        reader->setFocus(); QTest::keyClick(reader, Qt::Key_L, Qt::ControlModifier);
        QTRY_VERIFY(window.search_->hasFocus() && window.search_->isVisible());
        QVERIFY(window.language_->isEnabled() && window.language_->isVisible());
        window.language_->setFocus(); QTRY_VERIFY(window.language_->hasFocus());
        QTest::keyClick(window.language_, Qt::Key_Space);
        QTRY_VERIFY(window.language_->view()->isVisible());
        QTest::keyClick(window.language_->view(), Qt::Key_Escape);
        QTRY_VERIFY(!window.language_->view()->isVisible());
        QTest::keyClick(window.language_, Qt::Key_L, Qt::ControlModifier);
        QTRY_VERIFY(window.search_->hasFocus());
        QTest::keyClicks(window.search_, "cat"); QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTRY_VERIFY(!window.readingUncommitted_ && reader->hasFocus());
        QVERIFY(window.learning_.isBookmarked(catKey));
        QVERIFY(window.listen_->isEnabled() && window.bookmark_->isEnabled());
        QVERIFY(window.resultStatus_->text() != failure);
        for (int width : {640, 900}) {
            window.resize(width, 640); QTRY_COMPARE(window.width(), width);
            QTRY_VERIFY(reader->isVisible() && reader->viewport()->isVisible());
            if (width < 720) {
                QTRY_VERIFY(window.searchPane_->isHidden());
                QTRY_COMPARE(window.readerContent_->geometry(), window.readerSplit_->contentsRect());
            } else {
                QTRY_VERIFY(window.searchPane_->isVisible());
                QTRY_COMPARE(window.readerSplit_->sizes().at(0), wideSidebarWidth);
                QTRY_COMPARE(window.readerContent_->geometry().right(), window.readerSplit_->contentsRect().right());
            }
            QVERIFY(!reader->document()->toPlainText().contains(failure));
            QVERIFY(window.grab().save(frameStem + QStringLiteral("-recovered-%1.png").arg(width)));
        }
        // An intentionally empty body is a successful entry, not a failed or loading surface.
        const QJsonObject empty{{"title", "Controlled empty entry"}, {"language", "English"},
            {"language_code", "en"}, {"kind", "language"}, {"sections", QJsonArray{}}, {"media", QJsonArray{}}};
        QVERIFY(window.renderResponse(response(empty)));
        QVERIFY(!window.readingUncommitted_ && !window.loading_);
        QVERIFY(!reader->document()->toPlainText().contains(failure));
        QVERIFY(window.listen_->isEnabled() && window.bookmark_->isEnabled());
    }


    void readingInitialImportRejectsSameDocumentReplacement() {
        MainWindow window{QString()};
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        QPointer<QTextDocument> document(window.reading_->document());
        const QString authored = QStringLiteral("Initial import body");
        const QJsonObject entry{{"title", "Initial import control"}, {"language_code", "en"},
            {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2},
                {"blocks", QJsonArray{QJsonObject{{"kind", "heading"}, {"level", 3},
                    {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", authored}}}}}}}}}}};
        window.currentEntry_ = entry;
        bool replaced = false; QString replacement;
        const auto connection = connect(document, &QTextDocument::contentsChanged, &window, [&] {
            if (replaced || !document || !document->toPlainText().contains(authored)) return;
            replaced = true; replacement = QString(document->characterCount() - 1, QChar('Z'));
            document->setPlainText(replacement);
        });
        const auto cleanup = qScopeGuard([&] { disconnect(connection); });
        QVERIFY(!window.refreshReading());
        QVERIFY(replaced && document);
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(document->toPlainText(), replacement);
        QVERIFY(!document->isLayoutEnabled());
        QVERIFY(window.readingUncommitted_ && window.readingLogicalOwners_.isEmpty());
        QCOMPARE(window.statusBar()->currentMessage(), QStringLiteral("This entry could not be displayed. Your dictionary data is unchanged. Choose another entry or language."));
        disconnect(connection);
        QVERIFY(window.refreshReading());
        QVERIFY(document->isLayoutEnabled());
        QVERIFY(document->toPlainText().contains(authored));
    }

    void readingOldRegistrationClearPreservesRawReplacement() {
        MainWindow window{QString()}; window.resize(900, 640); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 120000);
        const QJsonObject entry{{"title", "Clear registration control"}, {"language_code", "en"},
            {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2},
                {"blocks", QJsonArray{QJsonObject{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""},
                    {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "Existing registered body"}}}}}}}}}}};
        window.currentEntry_ = entry; QVERIFY(window.refreshReading());
        QPointer<QTextDocument> document(window.reading_->document());
        QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
        layout->documentSize();
        const QString replacement(document->characterCount() - 1, QChar('X'));
        bool replaced = false;
        const auto connection = connect(layout, &QAbstractTextDocumentLayout::update, &window, [&](const QRectF &) {
            if (replaced || !document) return;
            replaced = true; document->setPlainText(replacement);
        });
        const auto cleanup = qScopeGuard([&] { disconnect(connection); });
        QVERIFY(!window.refreshReading());
        QVERIFY(replaced && document);
        QCOMPARE(document->toPlainText(), replacement);
        QVERIFY(!document->isLayoutEnabled());
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(window.readingLogicalOwners_.isEmpty());
        disconnect(connection);
        QVERIFY(window.refreshReading());
        QVERIFY(document->isLayoutEnabled());
        QVERIFY(document->toPlainText().contains(QStringLiteral("Existing registered body")));
        QCOMPARE(LogicalFlow::inventory(document), LogicalFlow::Status::Handled);
    }


    void readingFragmentAndVisitRestoreFailBeforeHistoryCommit() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 120000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const bool oldCollapse = window.learning_.settings().collapseEtymology;
        const bool oldHistory = window.learning_.settings().historyEnabled;
        window.learning_.setCollapseEtymology(true);
        window.learning_.setHistoryEnabled(true);
        const auto restoreSettings = qScopeGuard([&] {
            window.learning_.setCollapseEtymology(oldCollapse); window.learning_.setHistoryEnabled(oldHistory);
        });
        const auto history = [&] {
            QJsonArray rows;
            for (const auto &word : window.learning_.history()) rows.append(QJsonObject{
                {"key", word.key}, {"title", word.title}, {"language", word.language}, {"kind", word.kind},
                {"clue", word.clue}, {"originRoot", word.originRoot}, {"originEdition", word.originEdition},
                {"savedAt", word.savedAt}, {"lastViewed", word.lastViewed}, {"views", word.views}});
            return rows;
        };
        const QJsonObject zero{{"unit", "em"}, {"value", 0}};
        const QJsonObject edges{{"top", QJsonObject{{"unit", "em"}, {"value", double(std::numeric_limits<float>::max())}}},
            {"right", zero}, {"bottom", zero}, {"left", zero}};
        const QJsonObject block{{"kind", "paragraph"}, {"depth", 0}, {"list_path", ""},
            {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "Collapsed unavailable content"}}}},
            {"style", QJsonObject{{"padding", edges}}}};
        const QJsonObject entry{{"title", "Controlled restore refusal"}, {"kind", "language"},
            {"language", "English"}, {"language_code", "en"}, {"media", QJsonArray{}},
            {"sections", QJsonArray{QJsonObject{{"title", "Etymology"}, {"level", 3}, {"blocks", QJsonArray{block}}}}}};
        const QByteArray bytes = QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson();
        window.saveVisit();
        const int priorIndex = window.visitIndex_;
        const int priorCount = window.visits_.size();
        const auto priorHistory = history();
        const auto priorWord = QSettings().value(QStringLiteral("reader/lastWord"));
        const auto savedVisit = window.visits_[priorIndex];
        // Default folding succeeds; the requested fragment exposes the invalid layout.
        QVERIFY(!window.renderResponse(bytes, true, QStringLiteral("Etymology")));
        QCOMPARE(window.currentEntry_, entry); QVERIFY(window.readingUncommitted_);
        QCOMPARE(window.visitIndex_, priorIndex); QCOMPARE(window.visits_.size(), priorCount);
        QCOMPARE(history(), priorHistory); QCOMPARE(QSettings().value(QStringLiteral("reader/lastWord")), priorWord);
        QVERIFY(!window.listen_->isEnabled() && !window.bookmark_->isEnabled());
        // Saved-state restoration is the second half of the ordinary history path.
        // Its failure must not commit the otherwise valid, folded first half.
        QVERIFY(window.renderResponse(bytes, false, std::nullopt, true));
        QVERIFY(window.collapsedSections_.contains(0));
        QVERIFY(window.readingUncommitted_);
        QCOMPARE(history(), priorHistory); QCOMPARE(QSettings().value(QStringLiteral("reader/lastWord")), priorWord);
        MainWindow::Visit openVisit = savedVisit;
        openVisit.collapsed.clear(); openVisit.cursorPosition = 1; openVisit.cursorAnchor = 1;
        QVERIFY(!window.restoreVisitReading(openVisit));
        QVERIFY(window.readingUncommitted_);
        QCOMPARE(window.visitIndex_, priorIndex); QCOMPARE(window.visits_.size(), priorCount);
        QCOMPARE(history(), priorHistory); QCOMPARE(QSettings().value(QStringLiteral("reader/lastWord")), priorWord);
        QCOMPARE(window.visits_[priorIndex].cursorPosition, savedVisit.cursorPosition);
        QCOMPARE(window.visits_[priorIndex].cursorAnchor, savedVisit.cursorAnchor);
        QCOMPARE(window.visits_[priorIndex].collapsed, savedVisit.collapsed);
        QVERIFY(!window.listen_->isEnabled() && !window.bookmark_->isEnabled());
        window.navigate(-1);
        QCOMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(!window.readingUncommitted_);
        QCOMPARE(window.visitIndex_, priorIndex);
    }


    void floatingTableKeepsFollowingHeadingAndParagraphSeparate() {
        QSettings().setValue("media/allowImages", false);
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(640, 600);
        window.show();
        QCoreApplication::processEvents();
        const auto text = [](const QString &value) {
            return QJsonObject{{"kind", "text"}, {"text", value}};
        };
        QJsonArray rows, media;
        for (int row = 0; row != 40; ++row) {
            QJsonArray cells;
            for (int column = 0; column != 7; ++column) {
                QJsonArray spans{text(QStringLiteral("Country %1 column %2").arg(row).arg(column))};
                if (column == 4 && (row == 1 || row == 39)) {
                    const QString file = QStringLiteral("Float fixture %1.svg").arg(row);
                    spans.append(QJsonObject{{"kind", "link"}, {"text", ""}, {"target", "File:" + file},
                        {"image", QJsonObject{{"file", file}, {"width_px", 30}, {"alt", QStringLiteral("Flag %1").arg(row)}}}});
                    media.append(QJsonObject{{"kind", "image"}, {"file", file}, {"caption", ""}});
                }
                cells.append(QJsonObject{{"header", row == 0}, {"spans", spans}});
            }
            rows.append(QJsonObject{{"cells", cells}});
        }
        const QJsonObject tableStyle{{"float_side", "left"}, {"background", "#fffacd"},
            {"collapse", "collapse"}, {"border", QJsonObject{{"solid", QJsonObject{
                {"width", QJsonObject{{"unit", "px"}, {"value", 1}}}, {"color", "#aaaaaa"}}}}}};
        const QJsonObject table{{"kind", "table"}, {"table", QJsonObject{{"rows", rows}, {"style", tableStyle}}}};
        const QJsonObject linkedParagraph{{"kind", "paragraph"}, {"spans", QJsonArray{
            QJsonObject{{"kind", "link"}, {"text", "References and further information:"},
                {"target", "Wiktionary:References"}, {"bold", true}}}}};
        const QJsonObject entry{{"title", "Floating table followed by references"}, {"kind", "language"},
            {"language", window.api_->language()}, {"sections", QJsonArray{
                QJsonObject{{"level", 2}, {"title", "Countries"}, {"blocks", QJsonArray{table}}},
                QJsonObject{{"level", 2}, {"title", "References"}, {"blocks", QJsonArray{linkedParagraph,
                    QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{text("Final reference sentinel")}}}}}}}},
            {"media", media}};
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        QTextDocument *document = window.reading_->document();
        const QString fullText = document->toPlainText();
        QCOMPARE(fullText.count(QChar::ObjectReplacementCharacter), 2);
        QVERIFY(fullText.contains("Country 39 column 6"));
        QVERIFY(fullText.contains("Final reference sentinel"));
        const auto settle = [&] {
            const auto done = std::make_shared<bool>(false);
            QTimer::singleShot(0, document, [document, done] {
                QTimer::singleShot(0, document, [done] { *done = true; });
            });
            return QTest::qWaitFor([done, &window] { return *done && !window.readingFloatLayoutScheduled_; }, 10000);
        };
        const auto disabled = [&] {
            int count = 0;
            for (QTextBlock block = document->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const QTextFragment fragment = it.fragment();
                    if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
                    if (fragment.charFormat().intProperty(SemanticHtml::inlineImageStateProperty)
                        != int(MediaPanel::InlineImageState::Disabled)) return false;
                    ++count;
                }
            return count == 2;
        };
        QJsonArray samples;
        const auto rect = [](const QRectF &r) { return QJsonArray{r.x(), r.y(), r.width(), r.height()}; };
        const auto layoutIsSeparate = [&](const QString &phase) {
            document->documentLayout()->documentSize();
            QTextBlock heading;
            for (QTextBlock block = document->begin(); block.isValid(); block = block.next())
                if (block.blockFormat().headingLevel() == 2 && block.text().contains("References")) { heading = block; break; }
            if (!heading.isValid()) return false;
            const QTextBlock paragraph = heading.next();
            if (!paragraph.isValid() || paragraph.text() != QStringLiteral("References and further information:")) return false;
            if (QTextCursor(heading).currentFrame() != document->rootFrame()
                || QTextCursor(paragraph).currentFrame() != document->rootFrame()) return false;
            QTextTable *actualTable = nullptr;
            for (QTextFrame *frame : document->rootFrame()->childFrames())
                if (auto *candidate = qobject_cast<QTextTable *>(frame)) actualTable = candidate;
            if (!actualTable || actualTable->rows() != 40 || actualTable->columns() != 7
                || actualTable->frameFormat().position() != QTextFrameFormat::FloatLeft) return false;
            if (actualTable->format().background().color() != QColor("#fffacd")) return false;
            if (!heading.layout()->lineCount() || !paragraph.layout()->lineCount()) return false;
            bool disjoint = true;
            for (int hi = 0; hi != heading.layout()->lineCount(); ++hi)
                for (int pi = 0; pi != paragraph.layout()->lineCount(); ++pi) {
                    // These are root-frame blocks: layout position plus local
                    // line rectangle is the actual document-space paint region.
                    const QRectF h = heading.layout()->lineAt(hi).naturalTextRect().translated(heading.layout()->position());
                    const QRectF p = paragraph.layout()->lineAt(pi).naturalTextRect().translated(paragraph.layout()->position());
                    if (h.intersects(p)) { qWarning() << phase << h << p; disjoint = false; }
                }
            bool hitsInOwnBlocks = true;
            QJsonArray lineRegions;
            for (const QTextBlock &block : {heading, paragraph})
                for (int i = 0; i != block.layout()->lineCount(); ++i) {
                    const QRectF line = block.layout()->lineAt(i).naturalTextRect().translated(block.layout()->position());
                    const int hit = document->documentLayout()->hitTest(line.center(), Qt::FuzzyHit);
                    const bool ownBlock = hit >= block.position() && hit < block.position() + block.length();
                    hitsInOwnBlocks = hitsInOwnBlocks && ownBlock;
                    lineRegions.append(QJsonObject{{"block_position", block.position()}, {"text", block.text()},
                        {"layout_position", QJsonArray{block.layout()->position().x(), block.layout()->position().y()}},
                        {"local_line_rect", rect(block.layout()->lineAt(i).naturalTextRect())},
                        {"document_line_rect", rect(line)}, {"center_hit", hit}, {"center_hit_in_block", ownBlock}});
                }
            bool actionPreserved = false;
            const QString expectedAction = QStringLiteral("dict:")
                + QString::fromLatin1(QUrl::toPercentEncoding(QStringLiteral("Wiktionary:References")));
            for (auto it = paragraph.begin(); !it.atEnd(); ++it) {
                const auto format = it.fragment().charFormat();
                actionPreserved |= format.isAnchor() && format.anchorHref() == expectedAction
                    && format.fontWeight() >= QFont::Bold;
            }
            const bool contentPreserved = window.currentEntry_ == entry && document->toPlainText() == fullText;
            QTextCursor cursor(document);
            cursor.setPosition(heading.position());
            window.reading_->setTextCursor(cursor);
            window.reading_->ensureCursorVisible();
            const bool captured = window.grab().save(QStringLiteral(".tmp/ui-screenshots/floating-table-") + phase + QStringLiteral(".png"));
            samples.append(QJsonObject{{"phase", phase}, {"viewport_width", window.reading_->viewport()->width()},
                {"text_width", document->textWidth()}, {"resize_callback_pending", window.readingFloatLayoutScheduled_},
                {"line_regions", lineRegions}, {"line_rects_disjoint", disjoint},
                {"hits_in_own_blocks", hitsInOwnBlocks}, {"exact_bold_action_preserved", actionPreserved},
                {"content_preserved", contentPreserved}, {"frame_saved", captured}});
            return disjoint && hitsInOwnBlocks && actionPreserved && contentPreserved && captured;
        };
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        bool allSeparate = layoutIsSeparate(QStringLiteral("initial"));
        QTRY_VERIFY_WITH_TIMEOUT(disabled(), 10000);
        QVERIFY(settle());
        allSeparate = layoutIsSeparate(QStringLiteral("settled")) && allSeparate;
        // Preserve another ordinary event-drain and paint at the same width so
        // a transient resize cannot masquerade as a persistent baseline error.
        QVERIFY(settle());
        allSeparate = layoutIsSeparate(QStringLiteral("settled-repeat")) && allSeparate;
        for (int width : {900, 480, 640}) {
            window.resize(width, 600);
            QVERIFY(settle());
            allSeparate = layoutIsSeparate(QStringLiteral("width-%1").arg(width)) && allSeparate;
        }
        window.refreshReading();
        QTRY_VERIFY_WITH_TIMEOUT(disabled(), 10000);
        QVERIFY(settle());
        allSeparate = layoutIsSeparate(QStringLiteral("recomposition")) && allSeparate;
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(document->toPlainText(), fullText);
        QFile report(QStringLiteral(".tmp/ui-screenshots/floating-table-reference-geometry-%1.json").arg(QCoreApplication::applicationPid()));
        QVERIFY(report.open(QIODevice::WriteOnly | QIODevice::NewOnly));
        const QByteArray reportBytes = QJsonDocument(QJsonObject{{"samples", samples}, {"all_separate", allSeparate}}).toJson();
        QCOMPARE(report.write(reportBytes), qint64(reportBytes.size()));
        report.close();
        QVERIFY2(allSeparate, "Floating-table reference geometry/action/content failed; inspect retained phase geometry and frames");
    }

    void inlineImageUpdatesBatchLargeTableWithoutLosingSemanticContent() {
        QSettings().setValue("media/allowImages", false);
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(900, 700);
        const auto text = [](const QString &value) {
            return QJsonObject{{"kind", "text"}, {"text", value}};
        };
        QJsonArray rows, media;
        QStringList expectedAlts, expectedActions;
        for (int row = 0; row != 195; ++row) {
            QJsonArray cells;
            for (int column = 0; column != 7; ++column) {
                QJsonArray spans{text(QStringLiteral("Cell %1:%2 ").arg(row).arg(column))};
                if (column == 0 && row > 0 && row < 194) {
                    const QString file = QStringLiteral("Batch flag %1.svg").arg(row);
                    const QString alt = QStringLiteral("Flag alternative %1").arg(row, 3, 10, QChar('0'));
                    const QString action = QStringLiteral("https://example.org/flag/%1").arg(row);
                    const QJsonObject image{{"file", file}, {"width_px", 30}, {"alt", alt}, {"tooltip", ""}};
                    spans.append(QJsonObject{{"kind", "external_link"}, {"text", ""}, {"target", action}, {"image", image}});
                    media.append(QJsonObject{{"kind", "image"}, {"file", file}, {"caption", ""}});
                    expectedAlts.append(alt); expectedActions.append(action);
                }
                cells.append(QJsonObject{{"spans", spans}});
            }
            rows.append(QJsonObject{{"cells", cells}});
        }
        const QJsonObject tableBlock{{"kind", "table"}, {"table", QJsonObject{{"rows", rows}}}};
        const QJsonObject sentinel{{"kind", "paragraph"}, {"spans", QJsonArray{text("Final semantic sentinel after all 1365 cells")}}};
        const QJsonObject section{{"level", 2}, {"title", "Large image table"}, {"blocks", QJsonArray{tableBlock, sentinel}}};
        const QJsonObject entry{{"title", "Batched image consumer fixture"}, {"kind", "language"},
            {"language", window.api_->language()}, {"sections", QJsonArray{section}}, {"references", QJsonArray{}}, {"media", media}};
        const auto render = [&](const QJsonObject &value) {
            window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{value}}}).toJson(), false);
        };
        const auto images = [&] {
            QList<QTextImageFormat> result;
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const QTextFragment fragment = it.fragment();
                    if (fragment.isValid() && fragment.charFormat().isImageFormat()) result.append(fragment.charFormat().toImageFormat());
                }
            return result;
        };
        const auto disabled = [&] {
            const auto formats = images();
            return formats.size() == 193 && std::all_of(formats.cbegin(), formats.cend(), [](const auto &format) {
                return format.intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Disabled);
            });
        };
        render(entry);
        QTextDocument *document = window.reading_->document();
        const QString logicalText = document->toPlainText();
        QVERIFY(logicalText.contains("Cell 194:6"));
        QVERIFY(logicalText.contains("Final semantic sentinel after all 1365 cells"));
        QSignalSpy changed(document, &QTextDocument::contentsChanged);
        QSignalSpy layoutUpdates(document->documentLayout(), &QAbstractTextDocumentLayout::update);
        QSignalSpy layoutSizes(document->documentLayout(), &QAbstractTextDocumentLayout::documentSizeChanged);
        QTRY_VERIFY_WITH_TIMEOUT(disabled(), 10000);
        // This counts the actual queued character-format transaction, not time.
        // The old per-URL implementation emits a separate change for each image.
        QCOMPARE(changed.count(), 1);
        qInfo() << "193-image queued format burst: contentsChanged" << changed.count()
                << "layout updates" << layoutUpdates.count() << "layout sizes" << layoutSizes.count();
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(document->toPlainText(), logicalText);
        const auto settled = images();
        QCOMPARE(settled.size(), 193);
        QSet<QString> names;
        for (int i = 0; i != settled.size(); ++i) {
            const auto &format = settled[i];
            names.insert(format.name());
            QCOMPARE(format.stringProperty(QTextFormat::ImageAltText), expectedAlts[i]);
            QCOMPARE(format.anchorHref(), expectedActions[i]);
            QVERIFY(format.hasProperty(QTextFormat::ImageTitle));
            QCOMPARE(format.stringProperty(QTextFormat::ImageTitle), QString());
            QVERIFY(format.width() >= 30.0);
            QVERIFY(format.height() > 0);
            QVERIFY(window.reading_->accessibleDescription().contains(expectedAlts[i]));
            QVERIFY(!document->resource(QTextDocument::ImageResource, QUrl(format.name())).value<QImage>().isNull());
        }
        QCOMPARE(names.size(), 193);
        // Repeated provider requests must repaint resources without writing an
        // identical format or losing any occurrence. Use a queued sentinel so
        // the check cannot pass before the real provider callbacks/drain run.
        const auto provider = document->resourceProvider();
        QVERIFY(bool(provider));
        changed.clear();
        for (int repeat = 0; repeat != 2; ++repeat)
            for (const auto &format : settled) provider(QUrl(format.name()));
        bool providerBurstDrained = false;
        QTimer::singleShot(0, document, [&] {
            QTimer::singleShot(0, document, [&] { providerBurstDrained = true; });
        });
        QTRY_VERIFY(providerBurstDrained);
        const auto repeated = images();
        qInfo() << "Duplicate image provider burst: formats equal" << (repeated == settled)
                << "contentsChanged" << changed.count();
        QCOMPARE(repeated, settled);
        QCOMPARE(changed.count(), 0);
        QCOMPARE(document->toPlainText(), logicalText);
        // Two synchronous recompositions invalidate pending work without an
        // entry change, and must still reapply all cached Disabled resources.
        const quint64 generation = window.inlineImageGeneration_;
        window.refreshReading();
        window.refreshReading();
        QCOMPARE(window.inlineImageGeneration_, generation);
        changed.clear();
        QTRY_VERIFY_WITH_TIMEOUT(disabled(), 10000);
        QCOMPARE(changed.count(), 1);
        QCOMPARE(images(), settled);
        QCOMPARE(document->toPlainText(), logicalText);
        // Pending old-entry callbacks cannot mutate or describe a replacement
        // entry. Its uncatalogued image follows the ordinary Error path.
        render(entry);
        const QJsonObject replacementImage{{"file", "Uncatalogued replacement.svg"}, {"width_px", 30}, {"alt", "Replacement alternative"}};
        const QJsonObject replacementSpan{{"kind", "text"}, {"text", ""}, {"image", replacementImage}};
        const QJsonObject replacementBlock{{"kind", "paragraph"}, {"spans", QJsonArray{text("Replacement body "), replacementSpan}}};
        QJsonObject replacement = entry;
        replacement.insert("title", "Replacement entry");
        replacement.insert("sections", QJsonArray{QJsonObject{{"level", 2}, {"title", "Replacement section"}, {"blocks", QJsonArray{replacementBlock}}}});
        replacement.insert("media", QJsonArray{});
        render(replacement);
        changed.clear();
        QTRY_VERIFY_WITH_TIMEOUT(images().size() == 1 && images().first().intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Error), 10000);
        QCOMPARE(changed.count(), 1);
        QCOMPARE(window.currentEntry_, replacement);
        QCOMPARE(images().first().stringProperty(QTextFormat::ImageAltText), QStringLiteral("Replacement alternative"));
        QVERIFY(window.reading_->accessibleDescription().contains("Replacement alternative"));
        QVERIFY(!window.reading_->accessibleDescription().contains("Flag alternative"));
        QVERIFY(document->toPlainText().contains("Replacement body"));
        QVERIFY(!document->toPlainText().contains("Final semantic sentinel"));
    }

    void initialInlineImageNormalizationBatchesFormatsAndRestoresLayout() {
        for (bool initialLayoutEnabled : {true, false}) {
            QTextDocument document;
            document.setLayoutEnabled(false);
            document.setTextWidth(640);
            QFont font; font.setPointSizeF(12); document.setDefaultFont(font);
            QString html = QStringLiteral("<p>Before all cells</p><table>");
            QList<QJsonObject> authored;
            QStringList urls;
            for (int row = 0; row != 195; ++row) {
                html += QStringLiteral("<tr>");
                for (int column = 0; column != 7; ++column) {
                    html += QStringLiteral("<td>Cell %1:%2 ").arg(row).arg(column);
                    if (column == 0 && row > 0 && row < 194) {
                        QJsonObject image{{"file", QStringLiteral("Normalization flag %1.svg").arg(row)}};
                        if (row % 3 == 0) {
                            image.insert("width_px", 30); image.insert("height_px", 15);
                            image.insert("alt", QStringLiteral("Authored alternative %1").arg(row));
                            image.insert("tooltip", QStringLiteral("Authored tooltip %1").arg(row));
                        } else if (row % 3 == 1) {
                            image.insert("width_px", 30); image.insert("alt", ""); image.insert("tooltip", "");
                        } else {
                            image.insert("height_px", 15);
                        }
                        image.insert("border", row % 2 == 0);
                        authored.append(image);
                        urls.append(SemanticHtml::inlineImageUrl(image).toString());
                        html += QStringLiteral("<a href=\"https://example.org/normalization/%1\">%2</a>")
                            .arg(row).arg(SemanticHtml::inlineImageHtml(image));
                    }
                    html += QStringLiteral("</td>");
                }
                html += QStringLiteral("</tr>");
            }
            html += QStringLiteral("</table><p>Final cell and semantic sentinel remain present</p>");
            document.setHtml(html);
            QImage cached(2, 3, QImage::Format_ARGB32_Premultiplied); cached.fill(Qt::red);
            for (const auto &url : urls) document.addResource(QTextDocument::ImageResource, QUrl(url), cached);
            document.setLayoutEnabled(initialLayoutEnabled);
            const auto images = [&] {
                QList<QPair<int, QTextImageFormat>> result;
                for (QTextBlock block = document.begin(); block.isValid(); block = block.next())
                    for (auto it = block.begin(); !it.atEnd(); ++it) {
                        const QTextFragment fragment = it.fragment();
                        if (fragment.isValid() && fragment.charFormat().isImageFormat())
                            result.append({fragment.position(), fragment.charFormat().toImageFormat()});
                    }
                return result;
            };
            const auto before = images();
            QCOMPARE(before.size(), 193);
            const QString plain = document.toPlainText();
            QVERIFY(plain.contains("Cell 194:6"));
            QVERIFY(plain.contains("Final cell and semantic sentinel remain present"));
            QList<QUrl> requests;
            QList<bool> layoutsAtRequest;
            document.setResourceProvider([&](const QUrl &url) -> QVariant {
                requests.append(url); layoutsAtRequest.append(document.isLayoutEnabled());
                return {};
            });
            QSignalSpy changes(&document, &QTextDocument::contentsChanged);
            SemanticHtml::normalizeImages(&document);
            QCOMPARE(changes.count(), 1);
            QCOMPARE(document.isLayoutEnabled(), initialLayoutEnabled);
            QCOMPARE(document.toPlainText(), plain);
            const auto after = images();
            QCOMPARE(after.size(), before.size());
            QCOMPARE(requests.size(), 193);
            for (int i = 0; i != after.size(); ++i) {
                const auto &format = after[i].second;
                const QJsonObject &image = authored[i];
                const int row = i + 1;
                QCOMPARE(after[i].first, before[i].first);
                QCOMPARE(format.name(), before[i].second.name());
                QCOMPARE(format.anchorHref(), before[i].second.anchorHref());
                QCOMPARE(format.anchorHref(), QStringLiteral("https://example.org/normalization/%1").arg(row));
                QCOMPARE(format.stringProperty(SemanticHtml::inlineImageExplanationProperty), before[i].second.toolTip());
                QCOMPARE(format.intProperty(SemanticHtml::inlineImageStateProperty), 1);
                QCOMPARE(format.stringProperty(SemanticHtml::inlineImageStatusProperty), QStringLiteral("Loading image."));
                QCOMPARE(format.width(), row % 3 == 2 ? 15.0 : 30.0);
                QCOMPARE(format.height(), row % 3 == 1 ? 30.0 : 15.0);
                QCOMPARE(format.hasProperty(QTextFormat::ImageAltText), image.contains("alt"));
                QCOMPARE(format.hasProperty(QTextFormat::ImageTitle), image.contains("tooltip"));
                if (image.contains("alt")) QCOMPARE(format.stringProperty(QTextFormat::ImageAltText), image.value("alt").toString());
                if (image.contains("tooltip")) {
                    QCOMPARE(format.stringProperty(QTextFormat::ImageTitle), image.value("tooltip").toString());
                    QCOMPARE(format.toolTip(), image.value("tooltip").toString());
                }
                QCOMPARE(format.boolProperty(SemanticHtml::inlineImageBorderProperty), row % 2 == 0);
                if (row % 2) QVERIFY(!format.hasProperty(SemanticHtml::inlineImageBorderProperty));
                QCOMPARE(requests[i], QUrl(urls[i]));
                QCOMPARE(layoutsAtRequest[i], initialLayoutEnabled);
                QCOMPARE(document.resource(QTextDocument::ImageResource, QUrl(urls[i])).value<QImage>(), cached);
            }
            // HTML replacement reuses cached resources. Every new occurrence
            // still gets normalized and re-requested after restoring layout.
            document.setLayoutEnabled(false);
            document.setHtml(html);
            for (const auto &url : urls) document.addResource(QTextDocument::ImageResource, QUrl(url), cached);
            document.setLayoutEnabled(initialLayoutEnabled);
            requests.clear(); layoutsAtRequest.clear(); changes.clear();
            SemanticHtml::normalizeImages(&document);
            QCOMPARE(changes.count(), 1);
            QCOMPARE(images(), after);
            QCOMPARE(document.toPlainText(), plain);
            QCOMPARE(requests.size(), 193);
            QVERIFY(std::all_of(layoutsAtRequest.cbegin(), layoutsAtRequest.cend(),
                [=](bool enabled) { return enabled == initialLayoutEnabled; }));
            // An image-free document must not acquire an empty transaction or
            // toggle a caller-disabled layout.
            document.setPlainText(QStringLiteral("No images, no format updates."));
            requests.clear(); changes.clear();
            SemanticHtml::normalizeImages(&document);
            QCOMPARE(changes.count(), 0);
            QVERIFY(requests.isEmpty());
            QCOMPARE(document.isLayoutEnabled(), initialLayoutEnabled);
            QCOMPARE(document.toPlainText(), QStringLiteral("No images, no format updates."));
        }
    }

    void typedInlineImagesUseRealBodyAndHeadingResourcesWithoutFilenameLabels() {
        QSettings().setValue("media/allowImages", true);
        QSettings().setValue("media/cacheMb", 10);
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(900, 700); window.show();
        const QString file = QStringLiteral("Inline fixture.svg");
        const QString sourceHost = LibraryStorage::sourceHost(window.api_->root());
        const QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/media-v1");
        QVERIFY(QDir().mkpath(cache));
        const QString key = QString::fromLatin1(QCryptographicHash::hash((sourceHost + ":image:" + file).toUtf8(), QCryptographicHash::Sha256).toHex());
        const QString payloadPath = cache + '/' + key + ".bin", metadataPath = cache + '/' + key + ".json";
        const auto removeFixture = qScopeGuard([&] { QFile::remove(payloadPath); QFile::remove(metadataPath); });
        // First-party synthetic SVG, never an invented copy of an HE asset.
        const QByteArray svg = R"svg(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="40" viewBox="0 0 20 40"><rect width="20" height="40" fill="#d13a30"/></svg>)svg";
        QFile payload(payloadPath); QVERIFY(payload.open(QIODevice::WriteOnly)); QCOMPARE(payload.write(svg), svg.size()); payload.close();
        const QJsonObject assetMetadata{{"url", "https://upload.wikimedia.org/wikipedia/commons/a/inline-fixture.svg"},
            {"source", "https://commons.wikimedia.org/wiki/File:Inline_fixture.svg"}, {"credit", "First-party test SVG"},
            {"intrinsic_width", 20}, {"intrinsic_height", 40}, {"original_mime", "image/svg+xml"}};
        QFile metadata(metadataPath); QVERIFY(metadata.open(QIODevice::WriteOnly));
        const QByteArray metadataBytes = QJsonDocument(assetMetadata).toJson(QJsonDocument::Compact);
        QCOMPARE(metadata.write(metadataBytes), metadataBytes.size()); metadata.close();
        const auto text = [](const QString &value) { return QJsonObject{{"kind", "text"}, {"text", value}}; };
        const auto occurrence = [&](QJsonObject image, const QString &kind, const QString &target) {
            return QJsonObject{{"kind", kind}, {"text", ""}, {"trail", ""}, {"target", target}, {"font_scale", 0}, {"image", image}};
        };
        const QJsonObject absentImage{{"file", file}, {"width_px", 15}};
        QJsonObject emptyImage = absentImage; emptyImage.insert("alt", ""); emptyImage.insert("tooltip", "");
        QJsonObject describedImage = absentImage; describedImage.insert("width_px", 20);
        describedImage.insert("alt", "Plain <alt> & data"); describedImage.insert("tooltip", "Tooltip <text> & data");
        const QJsonObject absent = occurrence(absentImage, "link", "File:" + file);
        const QJsonObject empty = occurrence(emptyImage, "text", "");
        QJsonObject described = occurrence(describedImage, "external_link", "https://example.org/image-action");
        described.insert("explanation", "Separate span explanation");
        const QJsonArray spans{text("A"), absent, text("B"), empty, text("C"), described};
        const QJsonObject tableCell{{"spans", QJsonArray{absent}}};
        const QJsonObject tableRow{{"cells", QJsonArray{tableCell}}};
        const QJsonObject table{{"rows", QJsonArray{tableRow}}};
        const QJsonObject paragraph{{"kind", "paragraph"}, {"spans", spans}};
        const QJsonObject tableBlock{{"kind", "table"}, {"table", table}};
        const QJsonObject section{{"level", 2}, {"title", "Inline section"}, {"blocks", QJsonArray{paragraph, tableBlock}}};
        const QJsonObject referenceBody{{"kind", "paragraph"}, {"spans", QJsonArray{described}}};
        const QJsonObject reference{{"kind", "note"}, {"number", 1}, {"group_number", 1}, {"spans", QJsonArray{}}, {"blocks", QJsonArray{referenceBody}}};
        const QJsonObject media{{"kind", "image"}, {"file", file}, {"caption", "Distinct retained catalogue caption"}};
        QJsonObject entry{{"title", "Inline consumer fixture"}, {"kind", "language"}, {"language", window.api_->language()},
            {"sections", QJsonArray{section}}, {"references", QJsonArray{reference}}, {"media", QJsonArray{media}}};
        const QJsonObject before = entry;
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        const auto images = [](QTextDocument *document) {
            QList<QTextImageFormat> result;
            for (QTextBlock block = document->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it)
                    if (it.fragment().charFormat().isImageFormat()) result.append(it.fragment().charFormat().toImageFormat());
            return result;
        };
        const auto ready = [&](QTextDocument *document) {
            const auto formats = images(document);
            return !formats.isEmpty() && std::all_of(formats.begin(), formats.end(), [](const auto &format) { return format.intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Ready); });
        };
        QTRY_VERIFY_WITH_TIMEOUT(ready(window.reading_->document()), 10000);
        const auto formats = images(window.reading_->document()); QCOMPARE(formats.size(), 5);
        QCOMPARE(formats[0].width(), 15.0); QCOMPARE(formats[0].height(), 30.0);
        QVERIFY(!formats[0].hasProperty(QTextFormat::ImageAltText)); QVERIFY(!formats[0].hasProperty(QTextFormat::ImageTitle));
        QVERIFY(formats[1].hasProperty(QTextFormat::ImageAltText)); QCOMPARE(formats[1].stringProperty(QTextFormat::ImageAltText), QString());
        QVERIFY(!formats[1].isAnchor());
        QCOMPARE(formats[2].width(), 20.0); QCOMPARE(formats[2].height(), 40.0);
        QCOMPARE(formats[2].stringProperty(QTextFormat::ImageAltText), QStringLiteral("Plain <alt> & data"));
        QCOMPARE(formats[2].toolTip(), QStringLiteral("Tooltip <text> & data"));
        QCOMPARE(formats[2].stringProperty(SemanticHtml::inlineImageExplanationProperty), QStringLiteral("Separate span explanation"));
        QCOMPARE(formats[2].anchorHref(), QStringLiteral("https://example.org/image-action"));
        QVERIFY(!window.reading_->toPlainText().contains("Plain <alt> & data"));
        QCOMPARE(window.reading_->toPlainText().count("Distinct retained catalogue caption"), 1);
        QCOMPARE(entry, before);
        // Exercise the actual HeadingBrowser resource provider, not native
        // DISPLAYTITLE admission (which remains a separate producer policy).
        SemanticHtml::setHtml(window.title_, window.spansHtml(QJsonArray{text("Title "), absent}, 0, {}, {}, 30));
        QTRY_VERIFY_WITH_TIMEOUT(ready(window.title_->document()), 10000);
        QCOMPARE(images(window.title_->document()).first().width(), 15.0);
        QCOMPARE(images(window.title_->document()).first().height(), 30.0);
        QCOMPARE(window.title_->accessibleName(), QStringLiteral("Title "));
        // Recomposition reuses the same ready catalog asset and per-document key.
        window.refreshReading(); QTRY_VERIFY_WITH_TIMEOUT(ready(window.reading_->document()), 10000);
        auto *permission = window.media_->findChild<QCheckBox *>("mediaAllowImages"); QVERIFY(permission);
        permission->setChecked(false);
        QTRY_COMPARE(images(window.reading_->document()).first().intProperty(SemanticHtml::inlineImageStateProperty), int(MediaPanel::InlineImageState::Disabled));
        const auto unavailable = images(window.reading_->document());
        const QFontMetricsF fallbackMetrics(window.reading_->document()->defaultFont());
        QVERIFY(unavailable[2].width() >= fallbackMetrics.horizontalAdvance(QStringLiteral("Plain <alt> & data")));
        QVERIFY(unavailable[2].height() >= fallbackMetrics.height());
        const QImage fallback = window.reading_->document()->resource(QTextDocument::ImageResource, QUrl(unavailable[2].name())).value<QImage>();
        QVERIFY(!fallback.isNull());
        bool hasInk = false;
        for (int y = 0; y < fallback.height(); ++y)
            for (int x = 0; x < fallback.width(); ++x) hasInk |= qAlpha(fallback.pixel(x, y)) != 0;
        QVERIFY(hasInk);
        QCOMPARE(unavailable[2].stringProperty(QTextFormat::ImageAltText), QStringLiteral("Plain <alt> & data"));
        QCOMPARE(unavailable[2].anchorHref(), formats[2].anchorHref());
        QCOMPARE(unavailable[0].width(), 15.0); // Missing/empty alt never gains a filename label.
        QCOMPARE(unavailable[1].width(), 15.0);
        permission->setChecked(true); QTRY_VERIFY_WITH_TIMEOUT(ready(window.reading_->document()), 10000);
        QCOMPARE(images(window.reading_->document())[2].width(), 20.0);
        QCOMPARE(images(window.reading_->document())[2].height(), 40.0);
        // Authored height uses validated original dimensions, including vector
        // upscaling. These are synthetic pixels, not assumed public asset sizes.
        for (int height : {20, 40, 80}) {
            const QJsonObject heightImage{{"file", file}, {"height_px", height}, {"alt", ""}, {"tooltip", QJsonValue::Null}};
            const QJsonObject heightParagraph{{"kind", "paragraph"}, {"spans", QJsonArray{occurrence(heightImage, "text", "")}}};
            const QJsonObject heightSection{{"level", 2}, {"title", "Height-only image"}, {"blocks", QJsonArray{heightParagraph}}};
            QJsonObject heightEntry = entry;
            heightEntry.insert("sections", QJsonArray{heightSection}); heightEntry.insert("references", QJsonArray{});
            window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{heightEntry}}}).toJson(), false);
            QTRY_VERIFY_WITH_TIMEOUT(ready(window.reading_->document()), 10000);
            const auto heightFormats = images(window.reading_->document()); QCOMPARE(heightFormats.size(), 1);
            const auto heightFormat = heightFormats.first();
            QCOMPARE(heightFormat.width(), height / 2.0); QCOMPARE(heightFormat.height(), qreal(height));
            QVERIFY(heightFormat.hasProperty(QTextFormat::ImageAltText));
            QCOMPARE(heightFormat.stringProperty(QTextFormat::ImageAltText), QString());
            QVERIFY(!heightFormat.hasProperty(QTextFormat::ImageTitle)); QVERIFY(heightFormat.toolTip().isEmpty());
            QVERIFY(!heightFormat.isAnchor()); QVERIFY(heightFormat.anchorHref().isEmpty());
            const QImage pixels = window.reading_->document()->resource(QTextDocument::ImageResource, QUrl(heightFormat.name())).value<QImage>();
            QVERIFY(!pixels.isNull()); QCOMPARE(pixels.pixelColor(pixels.width() / 2, pixels.height() / 2), QColor("#d13a30"));
            QVERIFY(window.reading_->accessibleDescription().isEmpty());
            QCOMPARE(window.reading_->toPlainText().count(file), 1); // The ordinary Media catalogue link remains.
            const QTextCursor catalogue = window.reading_->document()->find(file);
            QVERIFY(!catalogue.isNull()); QVERIFY(catalogue.charFormat().isAnchor());
            QCOMPARE(QUrl(catalogue.charFormat().anchorHref()), QUrl(QStringLiteral("https://commons.wikimedia.org/wiki/File:%1")
                .arg(QString::fromLatin1(QUrl::toPercentEncoding(file)))));
            int imageParagraphs = 0;
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next()) {
                if (!block.text().contains(QChar::ObjectReplacementCharacter)) continue;
                ++imageParagraphs;
                QCOMPARE(block.text(), QString(QChar::ObjectReplacementCharacter));
            }
            QCOMPARE(imageParagraphs, 1); // No filename or alternative-text substitution in the image paragraph.
            QCOMPARE(window.currentEntry_, heightEntry);
            QCoreApplication::processEvents();
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-height-only-svg-%1.png").arg(height)));
        }
        // An uncatalogued image produces the ordinary consumer Error without
        // network access; preserve the authored-alt fallback and recovery checks.
        QJsonObject errorImage{{"file", "Missing inline fixture.svg"}, {"height_px", 15}, {"alt", QString::fromUtf8("וי")}};
        const QJsonObject errorParagraph{{"kind", "paragraph"}, {"spans", QJsonArray{occurrence(errorImage, "text", "")}}};
        const QJsonObject errorSection{{"level", 2}, {"title", "Unavailable image"}, {"blocks", QJsonArray{errorParagraph}}};
        QJsonObject errorEntry = entry;
        errorEntry.insert("sections", QJsonArray{errorSection});
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{errorEntry}}}).toJson(), false);
        QTRY_COMPARE(images(window.reading_->document()).first().intProperty(SemanticHtml::inlineImageStateProperty), int(MediaPanel::InlineImageState::Error));
        const auto errorFormat = images(window.reading_->document()).first();
        QCOMPARE(errorFormat.stringProperty(SemanticHtml::inlineImageStatusProperty), QStringLiteral("This image is not in the dictionary's media catalogue."));
        QCOMPARE(errorFormat.stringProperty(QTextFormat::ImageAltText), QString::fromUtf8("וי"));
        QVERIFY(errorFormat.width() >= fallbackMetrics.horizontalAdvance(QString::fromUtf8("וי")));
        QVERIFY(errorFormat.height() >= fallbackMetrics.height());
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        QTRY_VERIFY_WITH_TIMEOUT(ready(window.reading_->document()), 10000);
        // Copy preserves the occurrence/action/optional fields without a filename
        // text substitution. Portable external clipboard raster embedding is not claimed.
        QTextCursor selected(window.reading_->document()); selected.setPosition(1); selected.setPosition(2, QTextCursor::KeepAnchor);
        // Find the real first image offset, independent of section furniture.
        for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next()) {
            bool found = false;
            for (auto it = block.begin(); !it.atEnd(); ++it) if (it.fragment().charFormat().isImageFormat()) {
                selected.setPosition(it.fragment().position()); selected.setPosition(it.fragment().position() + 1, QTextCursor::KeepAnchor); found = true; break;
            }
            if (found) break;
        }
        window.reading_->setTextCursor(selected); window.reading_->copy();
        QVERIFY(!QApplication::clipboard()->text().contains(file));
        QTextDocument copied; SemanticHtml::setHtml(&copied, QApplication::clipboard()->mimeData()->html());
        QCOMPARE(images(&copied).first().anchorHref(), formats[0].anchorHref());
        QVERIFY(!images(&copied).first().hasProperty(QTextFormat::ImageAltText));
        auto *accessible = QAccessible::queryAccessibleInterface(window.reading_); QVERIFY(accessible && accessible->textInterface());
        int start = -1, end = -1; const QString attributes = accessible->textInterface()->attributes(selected.selectionStart(), &start, &end);
        QVERIFY(attributes.contains("xml-roles:img;")); QVERIFY(!attributes.contains("image-alt:"));
        // Unknown edition remains explicitly unresolved on the real click route.
        window.media_->setEntry(entry, {});
        const QJsonObject current = window.currentEntry_;
        QVERIFY(clickAnchor(window.reading_, formats[0].anchorHref()));
        QCOMPARE(window.currentEntry_, current);
        QVERIFY(window.statusBar()->currentMessage().contains("does not identify the source"));
        QJsonObject legacy = text("Legacy"); QJsonObject nullImage = legacy; nullImage.insert("image", QJsonValue::Null);
        QCOMPARE(window.spansHtml(QJsonArray{legacy}), window.spansHtml(QJsonArray{nullImage}));
        for (const QString &bad : {QStringLiteral("bad_file.svg"), QStringLiteral(" bad.svg"), QStringLiteral("bad#file.svg")}) {
            QJsonObject image = absentImage; image.insert("file", bad);
            QVERIFY_EXCEPTION_THROWN(window.spansHtml(QJsonArray{occurrence(image, "text", "")}), std::runtime_error);
        }
        QJsonObject ordinaryFile{{"kind", "link"}, {"text", "File link"}, {"target", "File:" + file}};
        QVERIFY(window.spansHtml(QJsonArray{ordinaryFile}).contains("href='dict:"));
        QVERIFY(!window.spansHtml(QJsonArray{ordinaryFile}).contains("media-source:"));
        QTextImageFormat geometry;
        SemanticHtml::imageDimensions(geometry, QJsonObject{{"file", file}, {"width_px", 15}, {"height_px", 20}}, window.reading_->document(), QSizeF(100, 300));
        QCOMPARE(geometry.width(), 6.0); QCOMPARE(geometry.height(), 20.0);
        SemanticHtml::imageDimensions(geometry, QJsonObject{{"file", file}, {"width_px", 15}}, window.reading_->document(), QSizeF(2, 1));
        QCOMPARE(geometry.width(), 15.0); QCOMPARE(geometry.height(), 8.0);
        SemanticHtml::imageDimensions(geometry, QJsonObject{{"file", file}, {"height_px", 100}}, window.reading_->document(), QSizeF(100, 50));
        QCOMPARE(geometry.width(), 100.0); QCOMPARE(geometry.height(), 50.0);
        // Source-proven ORIGINAL HE sizes, not downloaded960px raster ratios:
        // those thumbnails differ by one pixel on the first two actual assets.
        for (const auto &sample : {qMakePair(QSizeF(128, 214), qreal(25)),
                qMakePair(QSizeF(525, 600), qreal(17)), qMakePair(QSizeF(600, 600), qreal(15))}) {
            SemanticHtml::imageDimensions(geometry, QJsonObject{{"file", file}, {"width_px", 15}}, window.reading_->document(), sample.first);
            QCOMPARE(geometry.width(), 15.0); QCOMPARE(geometry.height(), sample.second);
        }
        const QString unicodeEdge = QString(QChar(0x00a0)) + QStringLiteral("edge.svg") + QString(QChar(0x00a0));
        QCOMPARE(SemanticHtml::checkedImage(QJsonObject{{"file", unicodeEdge}, {"width_px", 15}}).value("file").toString(), unicodeEdge);
        QJsonObject huge = absentImage; huge.insert("width_px", 4294967295.0);
        QCOMPARE(SemanticHtml::inlineImageData(SemanticHtml::inlineImageUrl(huge)).value("width_px").toDouble(), 4294967295.0);
        QJsonObject zeroAxis = absentImage; zeroAxis.insert("width_px", 0);
        QVERIFY_EXCEPTION_THROWN(SemanticHtml::inlineImageHtml(zeroAxis), std::runtime_error);
        QVERIFY_EXCEPTION_THROWN(window.spansHtml(QJsonArray{occurrence(absentImage, "line_break", "")}), DictApiError);
    }


    void unavailableInlineImagesKeepAlternativesGeometryAndReadyTransparency() {
        // Hold ordinary media requests in memory: no socket or public opt-in.
        class HeldReply final : public QNetworkReply {
        public:
            HeldReply(const QNetworkRequest &request, QObject *parent) : QNetworkReply(parent) {
                setRequest(request); setUrl(request.url()); setOperation(QNetworkAccessManager::GetOperation);
                open(QIODevice::ReadOnly);
            }
            void complete(const QByteArray &bytes, NetworkError error = NoError) {
                if (isFinished()) return;
                bytes_ = bytes;
                if (error != NoError) setError(error, QStringLiteral("Controlled unavailable image"));
                setHeader(QNetworkRequest::ContentLengthHeader, bytes_.size());
                emit metaDataChanged();
                if (!bytes_.isEmpty()) emit readyRead();
                setFinished(true); emit finished();
            }
            void abort() override { complete({}, OperationCanceledError); }
            qint64 bytesAvailable() const override { return bytes_.size() - offset_ + QNetworkReply::bytesAvailable(); }
        protected:
            qint64 readData(char *data, qint64 maximum) override {
                const qint64 count = qMin(maximum, bytes_.size() - offset_);
                if (count <= 0) return -1;
                std::copy_n(bytes_.constData() + offset_, count, data); offset_ += count; return count;
            }
        private:
            QByteArray bytes_;
            qint64 offset_ = 0;
        };
        class HeldNetwork final : public QNetworkAccessManager {
        public:
            QList<QUrl> urls;
            QList<QPointer<HeldReply>> replies;
        protected:
            QNetworkReply *createRequest(Operation, const QNetworkRequest &request, QIODevice *) override {
                urls.append(request.url());
                auto *reply = new HeldReply(request, this); replies.append(reply); return reply;
            }
        } network;
        QSettings().setValue("media/allowImages", false);
        QSettings().setValue("media/cacheMb", 10);
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(900, 700); window.show();
        // Reuse MediaPanel's existing dependency seam; the real document provider
        // resolves this current panel through MainWindow on every request.
        delete window.media_;
        window.media_ = new MediaPanel(window.entryTabs_, &network);
        window.entryTabs_->insertTab(1, window.media_, QStringLiteral("Media && speech"));
        const QString file = QStringLiteral("Controlled transparent placeholder.png");
        const QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/media-v1/";
        const QString sourceHost = LibraryStorage::sourceHost(window.api_->root());
        const QString key = QString::fromLatin1(QCryptographicHash::hash((sourceHost + ":image:" + file).toUtf8(), QCryptographicHash::Sha256).toHex());
        const QString payloadPath = cache + key + ".bin", metadataPath = cache + key + ".json";
        QVERIFY(!QFileInfo::exists(payloadPath)); QVERIFY(!QFileInfo::exists(metadataPath));
        const auto removeFixture = qScopeGuard([&] { QFile::remove(payloadPath); QFile::remove(metadataPath); });
        const QJsonObject missing{{"file", file}, {"width_px", 62}, {"height_px", 30}, {"tooltip", "Authored tooltip"}};
        QJsonObject nullAlt = missing; nullAlt.insert("alt", QJsonValue::Null);
        QJsonObject emptyAlt = missing; emptyAlt.insert("alt", "");
        QJsonObject authoredAlt = missing; authoredAlt.insert("alt", "Authored alternative");
        const QList<QJsonObject> alternatives{missing, nullAlt, emptyAlt, authoredAlt};
        QJsonArray spans;
        for (int i = 0; i < alternatives.size(); ++i) {
            spans.append(QJsonObject{{"kind", "text"}, {"text", QString::number(i) + " "}});
            spans.append(QJsonObject{{"kind", i == 2 ? "text" : "link"}, {"text", ""},
                {"target", i == 2 ? "" : "cat"}, {"image", alternatives[i]}});
        }
        const QJsonObject paragraph{{"kind", "paragraph"}, {"spans", spans}};
        const QJsonObject entry{{"title", "Unavailable image alternatives"}, {"kind", "language"},
            {"language", window.api_->language()}, {"sections", QJsonArray{QJsonObject{{"level", 2}, {"title", "Images"}, {"blocks", QJsonArray{paragraph}}}}},
            {"media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", file}, {"caption", "Controlled transparent artwork"}}}}};
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        const auto images = [&] {
            QList<QTextImageFormat> formats;
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it)
                    if (it.fragment().charFormat().isImageFormat()) formats.append(it.fragment().charFormat().toImageFormat());
            return formats;
        };
        const auto allState = [&](MediaPanel::InlineImageState state) {
            const auto formats = images();
            return formats.size() == 4 && std::all_of(formats.begin(), formats.end(), [&](const auto &format) {
                return format.intProperty(SemanticHtml::inlineImageStateProperty) == int(state);
            });
        };
        const auto hasInk = [](const QImage &pixels) {
            for (int y = 0; y < pixels.height(); ++y)
                for (int x = 0; x < pixels.width(); ++x)
                    if (qAlpha(pixels.pixel(x, y))) return true;
            return false;
        };
        const QString plain = window.reading_->toPlainText();
        const auto verify = [&](bool ready, const QString &stage) {
            const auto formats = images(); QCOMPARE(formats.size(), 4);
            for (int i = 0; i < formats.size(); ++i) {
                const auto &format = formats[i];
                const QImage pixels = window.reading_->document()->resource(QTextDocument::ImageResource, QUrl(format.name())).value<QImage>();
                QVERIFY(!pixels.isNull());
                QCOMPARE(hasInk(pixels), !ready && i != 2);
                QCOMPARE(format.anchorHref(), i == 2 ? QString() : QStringLiteral("dict:cat"));
                QCOMPARE(format.toolTip(), QStringLiteral("Authored tooltip"));
                QCOMPARE(format.hasProperty(QTextFormat::ImageAltText), i >= 2);
                if (i >= 2) QCOMPARE(format.stringProperty(QTextFormat::ImageAltText), alternatives[i].value("alt").toString());
                if (ready || i != 3) { QCOMPARE(format.width(), 62.0); QCOMPARE(format.height(), 30.0); }
                else QVERIFY(format.width() >= QFontMetricsF(window.reading_->document()->defaultFont()).horizontalAdvance("Authored alternative"));
                QCOMPARE(format.stringProperty(SemanticHtml::inlineImageStatusProperty).isEmpty(), ready);
            }
            QCOMPARE(window.currentEntry_, entry); QCOMPARE(window.reading_->toPlainText(), plain);
            QVERIFY(window.reading_->accessibleDescription().contains("Authored alternative"));
            QVERIFY(!window.reading_->accessibleDescription().contains(file));
            QVERIFY(QDir().mkpath(".tmp/ui-screenshots"));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/inline-placeholder-%1.png").arg(stage)));
        };
        QTRY_VERIFY(allState(MediaPanel::InlineImageState::Disabled));
        QCOMPARE(network.urls.size(), 0); verify(false, "disabled");
        auto *permission = window.media_->findChild<QCheckBox *>("mediaAllowImages"); QVERIFY(permission);
        permission->setChecked(true);
        QTRY_VERIFY(allState(MediaPanel::InlineImageState::Loading));
        QCOMPARE(network.urls.size(), 1); QVERIFY(network.replies.last()); verify(false, "loading");
        network.replies.last()->complete({}, QNetworkReply::ContentNotFoundError);
        QTRY_VERIFY(allState(MediaPanel::InlineImageState::Error));
        verify(false, "error");
        auto *load = window.media_->findChild<QPushButton *>("mediaLoad"); QVERIFY(load && load->isEnabled());
        load->click();
        QTRY_VERIFY(allState(MediaPanel::InlineImageState::Loading));
        QCOMPARE(network.urls.size(), 2); QVERIFY(network.replies.last());
        const QJsonObject info{{"url", "https://upload.wikimedia.org/wikipedia/commons/0/00/controlled-transparent.png"},
            {"descriptionurl", "https://commons.wikimedia.org/wiki/File:Controlled_transparent_placeholder.png"},
            {"width", 62}, {"height", 30}, {"mime", "image/png"}};
        const QJsonObject page{{"imageinfo", QJsonArray{info}}};
        network.replies.last()->complete(QJsonDocument(QJsonObject{{"query", QJsonObject{{"pages", QJsonArray{page}}}}}).toJson());
        QTRY_COMPARE(network.urls.size(), 3); QVERIFY(network.replies.last());
        QImage transparent(62, 30, QImage::Format_ARGB32_Premultiplied); transparent.fill(Qt::transparent);
        QByteArray png; QBuffer buffer(&png); QVERIFY(buffer.open(QIODevice::WriteOnly)); QVERIFY(transparent.save(&buffer, "PNG"));
        network.replies.last()->complete(png);
        QTRY_VERIFY(allState(MediaPanel::InlineImageState::Ready)); verify(true, "transparent-ready");
        permission->setChecked(false); QTRY_VERIFY(allState(MediaPanel::InlineImageState::Disabled));
        verify(false, "disabled-again");
        permission->setChecked(true); QTRY_VERIFY(allState(MediaPanel::InlineImageState::Ready));
        QCOMPARE(network.urls.size(), 3); verify(true, "transparent-recovered");
    }

    void imageBearingDisclosureRetainsKeyboardActivationAfterRecomposition() {
        QSettings().setValue("media/allowImages", false);
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(640, 600); window.show(); window.activateWindow();
        const QJsonObject image{{"kind", "text"}, {"text", ""}, {"image", QJsonObject{
            {"file", "Keyboard image.svg"}, {"width_px", 15}, {"alt", QString::fromUtf8("איקס")}}}};
        const QJsonObject paragraph{{"kind", "paragraph"}, {"spans", QJsonArray{
            QJsonObject{{"kind", "text"}, {"text", "BODY TO FOLD"}}, image}}};
        const QJsonObject heading{{"kind", "heading"}, {"level", 2}, {"spans", QJsonArray{
            QJsonObject{{"kind", "text"}, {"text", "Image section"}}, image}}};
        const QJsonObject section{{"level", 2}, {"title", "Image section"}, {"blocks", QJsonArray{heading, paragraph}}};
        const QJsonObject entry{{"title", "Keyboard image control"}, {"kind", "language"},
            {"language", window.api_->language()}, {"sections", QJsonArray{section}}};
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        const auto selectedAnchor = [&] {
            QTextCursor cursor = window.reading_->textCursor();
            if (!cursor.hasSelection()) return QString();
            cursor.setPosition(cursor.selectionStart());
            cursor.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            return cursor.charFormat().anchorHref();
        };
        QTest::keyClick(window.reading_, Qt::Key_Home, Qt::ControlModifier);
        QTest::keyClick(window.reading_, Qt::Key_Tab);
        QCOMPARE(selectedAnchor(), QStringLiteral("section:0"));
        // The second activation must work without moving the cursor or acquiring
        // focus again, including after queued inline-resource format updates.
        for (const auto key : {Qt::Key_Return, Qt::Key_Space}) {
            for (int cycle = 0; cycle < 2; ++cycle) {
                QTest::keyClick(window.reading_, key);
                QTRY_VERIFY(window.collapsedSections_.contains(0));
                QVERIFY(!window.reading_->toPlainText().contains("BODY TO FOLD"));
                QTRY_COMPARE(selectedAnchor(), QStringLiteral("section:0"));
                QTest::keyClick(window.reading_, key);
                QTRY_VERIFY(!window.collapsedSections_.contains(0));
                QVERIFY(window.reading_->toPlainText().contains("BODY TO FOLD"));
                QTRY_COMPARE(selectedAnchor(), QStringLiteral("section:0"));
            }
        }
        QCOMPARE(window.currentEntry_, entry);
    }

    void spaceActivatesNormalFallbackHeadingBeforeTable() {
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(640, 600); window.show(); window.activateWindow();
        // Exact first section of retained normal Reader dwa (28d426bc), including
        // all original table fields. There is no rich-heading companion block.
        const QJsonObject section = QJsonDocument::fromJson(QByteArrayLiteral(R"DICT({"level":2,"title":"Poloniera","anchor":"Poloniera","anchor_fallback":"","blocks":[{"kind":"table","depth":0,"spans":[],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":{"caption":[],"rows":[{"cells":[{"spans":[{"kind":"link","text":"1","target":"jeden","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"2","target":"","trail":"","language":"","classes":"center","direction":"","explanation":"","foreground":null,"font_scale":1.96992027759552,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"3","target":"trzy","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":2,"rowspan":1,"background":"#b4cdcd"}]},{"cells":[{"spans":[{"kind":"text","text":"Zenbaki kardinala","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"dwa","target":"","trail":"","language":"","classes":"mw-selflink selflink","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"Zenbaki ordinala","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"link","text":"drugi","target":"drugi","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"gender m","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":".","target":"","trail":"","language":"","classes":"gender m gender-period","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"; ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"drugie","target":"drugie","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"n","target":"","trail":"","language":"","classes":"gender n","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":".","target":"","trail":"","language":"","classes":"gender n gender-period","direction":"","explanation":"","foreground":null,"font_scale":0.949999988079071,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]}],"geometry":{"border":2,"cell_spacing":0,"cell_padding":4,"width":{"unit":"px","value":250}},"style":{"background":"#f9f9f9","border":{"solid":{"width":{"unit":"px","value":1},"color":"#aaaaaa"}},"collapse":"collapse"}}}]})DICT")).object();
        QCOMPARE(section.value("title").toString(), QStringLiteral("Poloniera"));
        QCOMPARE(section.value("blocks").toArray().size(), 1);
        QCOMPARE(section.value("blocks").toArray().first().toObject().value("kind").toString(), QStringLiteral("table"));
        const QJsonObject entry{{"title", "dwa"}, {"kind", "language"}, {"language", "poloniera"},
            {"sections", QJsonArray{section}}};
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        const QString body = window.reading_->toPlainText();
        QVERIFY(body.contains("Zenbaki kardinala"));
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        const auto selectedAnchor = [&] {
            QTextCursor cursor = window.reading_->textCursor();
            if (!cursor.hasSelection()) return QString();
            cursor.setPosition(cursor.selectionStart());
            cursor.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            return cursor.charFormat().anchorHref();
        };
        QSignalSpy activated(window.reading_, &QTextBrowser::anchorClicked);
        QTest::keyClick(window.reading_, Qt::Key_Home, Qt::ControlModifier);
        QTest::keyClick(window.reading_, Qt::Key_Tab);
        QCOMPARE(selectedAnchor(), QStringLiteral("section:0"));
        for (int cycle = 0; cycle < 2; ++cycle) {
            QTest::keyClick(window.reading_, Qt::Key_Space);
            QTRY_COMPARE(activated.count(), cycle * 2 + 1);
            QTRY_VERIFY(window.collapsedSections_.contains(0));
            QVERIFY(!window.reading_->toPlainText().contains("Zenbaki kardinala"));
            QTRY_COMPARE(selectedAnchor(), QStringLiteral("section:0"));
            QTest::keyClick(window.reading_, Qt::Key_Space);
            QTRY_COMPARE(activated.count(), cycle * 2 + 2);
            QTRY_VERIFY(!window.collapsedSections_.contains(0));
            QCOMPARE(window.reading_->toPlainText(), body);
            QTRY_COMPARE(selectedAnchor(), QStringLiteral("section:0"));
        }
        QCOMPARE(window.currentEntry_, entry);
    }

    void spaceOutsideDisclosureKeepsReaderScrollingAndLinkSemantics() {
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(640, 600); window.show(); window.activateWindow();
        const QJsonArray spans{
            QJsonObject{{"kind", "link"}, {"text", "Ordinary word link"}, {"target", "dog"}},
            QJsonObject{{"kind", "text"}, {"text", QStringLiteral(" Body text for scrolling.").repeated(200)}}};
        const QJsonObject paragraph{{"kind", "paragraph"}, {"spans", spans}};
        const QJsonObject section{{"level", 2}, {"title", "Disclosure"}, {"blocks", QJsonArray{paragraph}}};
        const QJsonObject entry{{"title", "Space controls"}, {"kind", "language"},
            {"language", window.api_->language()}, {"sections", QJsonArray{section}}};
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        const QString body = window.reading_->toPlainText();
        const auto selectedAnchor = [&] {
            QTextCursor cursor = window.reading_->textCursor();
            if (!cursor.hasSelection()) return QString();
            cursor.setPosition(cursor.selectionStart());
            cursor.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            return cursor.charFormat().anchorHref();
        };
        QSignalSpy activated(window.reading_, &QTextBrowser::anchorClicked);
        QTest::keyClick(window.reading_, Qt::Key_Home, Qt::ControlModifier);
        QTest::keyClick(window.reading_, Qt::Key_Tab);
        QCOMPARE(selectedAnchor(), QStringLiteral("section:0"));
        QTest::keyClick(window.reading_, Qt::Key_Space, Qt::ShiftModifier);
        QCOMPARE(activated.count(), 0);
        QVERIFY(window.collapsedSections_.isEmpty());
        QCOMPARE(window.reading_->toPlainText(), body);

        QTest::keyClick(window.reading_, Qt::Key_Tab);
        QCOMPARE(selectedAnchor(), QStringLiteral("dict:dog"));
        auto *scroll = window.reading_->verticalScrollBar();
        QTRY_VERIFY(scroll->maximum() > 0);
        scroll->setValue(0);
        QTest::keyClick(window.reading_, Qt::Key_Space);
        QTRY_VERIFY(scroll->value() > 0);
        QCOMPARE(activated.count(), 0);
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(window.collapsedSections_.isEmpty());
        QCOMPARE(window.reading_->toPlainText(), body);

        QTextCursor range = window.reading_->document()->find(QStringLiteral("Disclosure"));
        const QTextCursor bodyWord = window.reading_->document()->find(QStringLiteral(" Body text for scrolling."));
        QVERIFY(!range.isNull() && !bodyWord.isNull());
        range.setPosition(bodyWord.selectionEnd(), QTextCursor::KeepAnchor);
        window.reading_->setTextCursor(range);
        QCOMPARE(selectedAnchor(), QStringLiteral("section:0"));
        scroll->setValue(0);
        QTest::keyClick(window.reading_, Qt::Key_Space);
        QTRY_VERIFY(scroll->value() > 0);
        QCOMPARE(activated.count(), 0);
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(window.collapsedSections_.isEmpty());
        QCOMPARE(window.reading_->toPlainText(), body);

        QTextCursor plain(window.reading_->document());
        plain.setPosition(window.reading_->document()->characterCount() - 2);
        window.reading_->setTextCursor(plain);
        QVERIFY(!window.reading_->textCursor().hasSelection());
        scroll->setValue(0);
        QTest::keyClick(window.reading_, Qt::Key_Space);
        QTRY_VERIFY(scroll->value() > 0);
        QCOMPARE(activated.count(), 0);
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(window.collapsedSections_.isEmpty());
        QCOMPARE(window.reading_->toPlainText(), body);
    }

    void typedBlockAlignmentKeepsCellInheritanceAndOffsets() {
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const auto paragraph = [](const QString &text, const QJsonValue &align = QJsonValue()) {
            QJsonObject block{{"kind", "paragraph"}, {"spans", QJsonArray{QJsonObject{{"kind", "link"}, {"text", text}, {"target", "Alignment target"}}}}};
            if (!align.isUndefined()) block.insert("text_align", align);
            return block;
        };
        QJsonObject middle = paragraph("2", "center");
        QJsonObject middleSpan = middle.value("spans").toArray().first().toObject();
        middleSpan.insert("font_scale", 2.0); middle.insert("spans", QJsonArray{middleSpan});
        const QJsonObject cell{{"colspan", 2}, {"background", "#b4cdcd"}, {"style", QJsonObject{{"text_align", "right"}}},
            {"blocks", QJsonArray{paragraph("1"), middle, paragraph("3")}}};
        const QJsonObject table{{"geometry", QJsonObject{{"width", QJsonObject{{"unit", "px"}, {"value", 250}}}, {"border", 2}, {"cell_padding", 4}, {"cell_spacing", 0}}},
            {"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{cell}}}, QJsonObject{{"cells", QJsonArray{
                QJsonObject{{"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "A"}}}}},
                QJsonObject{{"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "B"}}}}}}}}}}};
        const QJsonObject source{{"kind", "table"}, {"table", table}};
        const QByteArray before = QJsonDocument(source).toJson(QJsonDocument::Compact);
        QString expectedText;
        for (const QString &direction : {QStringLiteral("ltr"), QStringLiteral("rtl")}) {
            QTextDocument document;
            document.setDefaultFont(QFont("DejaVu Sans", 12));
            SemanticHtml::setHtml(&document, QStringLiteral("<div dir='%1'>%2</div>").arg(direction, window.blockHtml(source)));
            for (const int width : {640, 900, 640}) {
                document.setTextWidth(width); (void)document.size();
                const QTextCursor one = document.find("1"), two = document.find("2"), three = document.find("3");
                QVERIFY(!one.isNull() && !two.isNull() && !three.isNull());
                QCOMPARE(one.blockFormat().alignment(), Qt::Alignment(Qt::AlignRight | Qt::AlignAbsolute));
                QCOMPARE(two.blockFormat().alignment(), Qt::Alignment(Qt::AlignHCenter));
                QCOMPARE(three.blockFormat().alignment(), one.blockFormat().alignment());
                QCOMPARE(one.currentTable(), two.currentTable());
                QCOMPARE(one.currentTable()->cellAt(0, 0).columnSpan(), 2);
                QCOMPARE(one.currentTable()->cellAt(0, 0).format().background().color(), QColor("#b4cdcd"));
                for (const QTextCursor &cursor : {one, two, three}) {
                    const QTextBlock block = cursor.block(); const QTextLine line = block.layout()->lineAt(0);
                    QVERIFY(line.isValid());
                    const qreal start = line.cursorToX(cursor.selectionStart() - block.position());
                    const qreal end = line.cursorToX(cursor.selectionEnd() - block.position());
                    if (cursor.selectedText() == QStringLiteral("2"))
                        QVERIFY(qAbs((start + end) / 2 - (line.x() + line.width() / 2)) < 1.0);
                    else QVERIFY(qAbs(qMax(start, end) - (line.x() + line.width())) < 1.0);
                    QCOMPARE(cursor.charFormat().anchorHref(), QStringLiteral("dict:Alignment%20target"));
                }
                QTextCursor selection(&document); selection.select(QTextCursor::Document);
                if (expectedText.isEmpty()) expectedText = selection.selectedText();
                QCOMPARE(selection.selectedText(), expectedText);
                QVERIFY(one.selectionStart() < two.selectionStart() && two.selectionStart() < three.selectionStart());
                // Explicit text alignment must not move the table frame itself.
                QCOMPARE(one.currentTable()->format().position(), QTextFrameFormat::InFlow);
            }
        }
        QCOMPARE(QJsonDocument(source).toJson(QJsonDocument::Compact), before);
        // Nested tables explicitly inherit cell text alignment; a child block
        // can still override it. Null and absent block fields remain identical.
        QJsonObject innerCell{{"blocks", QJsonArray{paragraph("Nested inherited"), paragraph("Nested override", "left")}}};
        QJsonObject inner{{"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{innerCell}}}}}};
        QJsonObject outerCell{{"style", QJsonObject{{"text_align", "right"}}}, {"blocks", QJsonArray{QJsonObject{{"kind", "table"}, {"table", inner}}}}};
        QTextDocument nested;
        SemanticHtml::setHtml(&nested, window.tableHtml(QJsonObject{{"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{outerCell}}}}}}, 0));
        QCOMPARE(nested.find("Nested inherited").blockFormat().alignment(), Qt::Alignment(Qt::AlignRight | Qt::AlignAbsolute));
        QCOMPARE(nested.find("Nested override").blockFormat().alignment(), Qt::Alignment(Qt::AlignLeft | Qt::AlignAbsolute));
        QTextTable *innerFrame = nested.find("Nested inherited").currentTable(); QVERIFY(innerFrame);
        QCOMPARE(innerFrame->format().position(), QTextFrameFormat::InFlow);
        QVERIFY(!innerFrame->format().hasProperty(QTextFormat::BlockAlignment));
        QCOMPARE(window.blockHtml(paragraph("Unchanged")), window.blockHtml(paragraph("Unchanged", QJsonValue::Null)));
        for (const QString &kind : {QStringLiteral("preformatted"), QStringLiteral("heading"), QStringLiteral("quotation"), QStringLiteral("list_item")}) {
            QJsonObject block = paragraph("First\nSecond", "right"); block.insert("kind", kind);
            QTextDocument aligned, original; SemanticHtml::setHtml(&aligned, window.blockHtml(block));
            block.remove("text_align"); SemanticHtml::setHtml(&original, window.blockHtml(block));
            QCOMPARE(aligned.toPlainText(), original.toPlainText());
            for (QTextBlock b = aligned.begin(); b.isValid(); b = b.next())
                if (!b.text().isEmpty()) QCOMPARE(b.blockFormat().alignment(), Qt::Alignment(Qt::AlignRight | Qt::AlignAbsolute));
        }
    }

    void typedTableFloatsWrapFollowingTextAndReflow() {
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const auto px = [](double value) { return QJsonObject{{"unit", "px"}, {"value", value}}; };
        const QJsonArray blocks{QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{
            QJsonObject{{"kind", "link"}, {"text", "Floating target"}, {"target", "Float destination"}}}}},
            QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "Tall cell\nsecond line\nthird line\nfourth line\nfifth line"}}}}}};
        const QJsonObject cell{{"blocks", blocks}};
        const QJsonObject geometry{{"width", QJsonObject{{"unit", "px"}, {"value", 250}}}, {"border", 2}, {"cell_padding", 4}, {"cell_spacing", 0}};
        QJsonObject table{{"geometry", geometry}, {"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{cell}}}}}};
        const QString prose = QStringLiteral("Following prose remains selectable and wraps around the actual floated table. ").repeated(18);
        const auto block = [](const QString &text) { return QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", text}}}}}; };
        for (const QString &side : {QStringLiteral("left"), QStringLiteral("right")}) {
            const QJsonObject margins{{"top", px(0)}, {"right", px(side == "left" ? 20 : 0)}, {"bottom", px(0)}, {"left", px(side == "right" ? 20 : 0)}};
            table.insert("style", QJsonObject{{"float_side", side}, {"margins", margins}});
            const QJsonObject source{{"kind", "table"}, {"table", table}, {"text_align", "right"}};
            for (const QString &direction : {QStringLiteral("ltr"), QStringLiteral("rtl")}) {
                QTextDocument document; document.setDefaultFont(QFont("DejaVu Sans", 12));
                const QString body = window.blockHtml(source) + window.blockHtml(block(prose)) + window.blockHtml(block("Following final paragraph"));
                SemanticHtml::setHtml(&document, QStringLiteral("<div dir='%1'>%2</div>").arg(direction, body));
                QJsonObject inFlowTable = table; inFlowTable.insert("style", QJsonObject{{"margins", margins}});
                QJsonObject inFlowSource = source; inFlowSource.insert("table", inFlowTable);
                QTextDocument reference; reference.setDefaultFont(document.defaultFont());
                SemanticHtml::setHtml(&reference, QStringLiteral("<div dir='%1'>%2</div>").arg(direction,
                    window.blockHtml(inFlowSource) + window.blockHtml(block(prose)) + window.blockHtml(block("Following final paragraph"))));
                QCOMPARE(document.toPlainText(), reference.toPlainText());
                const QString logical = document.toPlainText();
                QTextCursor originalSelection(&document); originalSelection.select(QTextCursor::Document);
                const QString selectedLogical = originalSelection.selectedText();
                for (const int width : {640, 900, 640}) {
                    document.setTextWidth(width); (void)document.size();
                    QTextCursor link = document.find("Floating target"); QVERIFY(!link.isNull());
                    QTextTable *frame = link.currentTable(); QVERIFY(frame);
                    QCOMPARE(frame->format().position(), side == "left" ? QTextFrameFormat::FloatLeft : QTextFrameFormat::FloatRight);
                    QCOMPARE(frame->format().width().rawValue(), 250.0);
                    QCOMPARE(frame->format().leftMargin(), side == "right" ? 20.0 : 0.0);
                    QCOMPARE(frame->format().rightMargin(), side == "left" ? 20.0 : 0.0);
                    const QRectF reportedFrame = document.documentLayout()->frameBoundingRect(frame);
                    const QSize rasterSize = document.size().toSize();
                    QVERIFY(rasterSize.width() > 0 && rasterSize.width() <= 4096 && rasterSize.height() > 0 && rasterSize.height() <= 4096);
                    QImage raster(rasterSize, QImage::Format_ARGB32_Premultiplied); raster.fill(Qt::white);
                    QPainter painter(&raster); document.drawContents(&painter); painter.end();
                    // This fixture begins with a bordered table. Qt's public frame rectangle
                    // includes its first-cell offset; measure the painted outer border instead.
                    const QRectF rootBox = document.documentLayout()->frameBoundingRect(document.rootFrame());
                    const QTextFrameFormat rootFormat = document.rootFrame()->frameFormat();
                    const qreal contentLeft = rootBox.left() + rootFormat.leftMargin();
                    const qreal contentRight = rootBox.right() - rootFormat.rightMargin();
                    const int paintTop = qRound(rootBox.top() + rootFormat.topMargin() + frame->format().topMargin());
                    QVERIFY(paintTop >= 0 && paintTop < raster.height());
                    int paintLeft = -1, paintRight = -1;
                    for (int x = 0; x < raster.width(); ++x) {
                        if (raster.pixelColor(x, paintTop) != QColor(Qt::white)) {
                            if (paintLeft < 0) paintLeft = x;
                            paintRight = x + 1;
                        }
                    }
                    QVERIFY(paintLeft >= 0 && paintRight > paintLeft);
                    for (int x = paintLeft; x < paintRight; ++x)
                        QVERIFY2(raster.pixelColor(x, paintTop) != QColor(Qt::white), "outer table border is not continuous");
                    int paintBottom = paintTop;
                    while (paintBottom < raster.height() && raster.pixelColor(paintLeft, paintBottom) != QColor(Qt::white)) ++paintBottom;
                    QVERIFY(paintBottom > paintTop && paintBottom < raster.height());
                    const QRectF paintedBox(paintLeft, paintTop, paintRight - paintLeft, paintBottom - paintTop);
                    const QRectF box = paintedBox.adjusted(-frame->format().leftMargin(), -frame->format().topMargin(),
                        frame->format().rightMargin(), frame->format().bottomMargin());
                    QCOMPARE(box.width(), frame->format().width().rawValue());
                    QCOMPARE(box.height(), reportedFrame.height());
                    if (side == "left") QCOMPARE(box.left(), contentLeft);
                    else QCOMPARE(box.right(), contentRight);
                    const QTextCursor following = document.find("Following prose"); QVERIFY(!following.isNull());
                    const QTextBlock paragraph = following.block(); const QTextLayout *layout = paragraph.layout();
                    const QPointF origin = document.documentLayout()->blockBoundingRect(paragraph).topLeft();
                    QVERIFY(layout->lineCount() > 1);
                    bool beside = false, below = false;
                    for (int i = 0; i < layout->lineCount(); ++i) {
                        const QTextLine line = layout->lineAt(i);
                        const QRectF rect = line.naturalTextRect().translated(origin);
                        if (rect.top() < box.bottom() && rect.bottom() > box.top()) {
                            beside = true;
                            if (side == "right") QVERIFY2(rect.right() <= box.left() + 1, "text overlaps the right float or its margin");
                            else QVERIFY2(rect.left() >= box.right() - 1, "text overlaps the left float or its margin");
                        }
                        if (rect.top() >= box.bottom()) below = true;
                    }
                    QVERIFY2(beside, "table was merely aligned or cleared instead of floated beside following text");
                    QVERIFY(below);
                    QCOMPARE(document.toPlainText(), logical);
                    QCOMPARE(link.selectedText(), QStringLiteral("Floating target"));
                    QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("dict:Float%20destination"));
                    const QTextBlock linkBlock = link.block(); const QTextLine linkLine = linkBlock.layout()->lineAt(0);
                    const QPointF linkOrigin = document.documentLayout()->blockBoundingRect(linkBlock).topLeft();
                    const qreal x = (linkLine.cursorToX(link.selectionStart() - linkBlock.position()) + linkLine.cursorToX(link.selectionEnd() - linkBlock.position())) / 2;
                    const QPointF point = linkOrigin + QPointF(x, linkLine.y() + linkLine.height() / 2);
                    QCOMPARE(document.documentLayout()->anchorAt(point), QStringLiteral("dict:Float%20destination"));
                    const int hit = document.documentLayout()->hitTest(point, Qt::ExactHit);
                    QVERIFY(hit >= link.selectionStart() && hit < link.selectionEnd());
                    QTextCursor selection(&document); selection.select(QTextCursor::Document);
                    QCOMPARE(selection.selectedText(), selectedLogical);
                }
            }
        }
    }

    void typedLayoutRejectsUnknownValuesAndPreservesLegacyDefaults() {
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject block{{"kind", "paragraph"}, {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "Original"}}}}};
        const QString original = window.blockHtml(block);
        block.insert("text_align", QJsonValue::Null); QCOMPARE(window.blockHtml(block), original);
        for (const QJsonValue &bad : {QJsonValue("start"), QJsonValue("justify"), QJsonValue(0), QJsonValue(QJsonObject{})}) {
            block.insert("text_align", bad); QVERIFY_EXCEPTION_THROWN(window.blockHtml(block), std::runtime_error);
            block.insert("kind", "blank"); QVERIFY_EXCEPTION_THROWN(window.blockHtml(block), std::runtime_error);
            block.insert("kind", "paragraph");
        }
        QJsonObject table{{"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{QJsonObject{{"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "Cell"}}}}}}}}}}};
        QTextDocument document;
        SemanticHtml::setHtml(&document, window.tableHtml(table, 0));
        const QString text = document.toPlainText();
        table.insert("style", QJsonObject{{"background", "#f9f9f9"}, {"float_side", QJsonValue::Null}});
        SemanticHtml::setHtml(&document, window.tableHtml(table, 0));
        QCOMPARE(document.find("Cell").currentTable()->format().position(), QTextFrameFormat::InFlow);
        QCOMPARE(document.toPlainText(), text);
        for (const QJsonValue &bad : {QJsonValue("none"), QJsonValue("inline-start"), QJsonValue(false)}) {
            table.insert("style", QJsonObject{{"float_side", bad}});
            QVERIFY_EXCEPTION_THROWN(SemanticHtml::setHtml(&document, window.tableHtml(table, 0)), std::runtime_error);
            const QJsonObject swatch{{"kind", "table"}, {"table", table}, {"feature", QJsonObject{{"kind", "color_swatch"}, {"data", "#123456"}}}};
            QVERIFY_EXCEPTION_THROWN(SemanticHtml::setHtml(&document, window.blockHtml(swatch)), std::runtime_error);
        }
        table.insert("style", QJsonObject{{"float_side", "right"}});
        const QJsonObject swatch{{"kind", "table"}, {"table", table}, {"feature", QJsonObject{{"kind", "color_swatch"}, {"data", "#123456"}}}};
        SemanticHtml::setHtml(&document, window.blockHtml(swatch));
        QVERIFY(!document.find("Cell").isNull());
        QCOMPARE(document.find("Cell").currentTable()->format().position(), QTextFrameFormat::FloatRight);
    }

    void raggedTableBackgroundKeepsEmptySlotsSpansAndAuthoredColors() {
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(640, 600);
        window.show();
        const auto cell = [](const QString &label) {
            return QJsonObject{{"spans", label.isEmpty() ? QJsonArray{} : QJsonArray{
                QJsonObject{{"kind", "text"}, {"text", label}}}}};
        };
        QJsonObject heading = cell("Two-column table heading");
        heading.insert("colspan", 2);
        QJsonObject linked{{"spans", QJsonArray{QJsonObject{{"kind", "link"},
            {"text", "Linked source"}, {"target", "Slot target#anchor"}}}}};
        QJsonObject spanning = cell(QString());
        spanning.insert("rowspan", 2);
        spanning.insert("background", "#ffc0cb");
        QJsonObject explicitEmpty = cell(QString());
        explicitEmpty.insert("background", "#d0ffd0");
        const QJsonArray rows{
            QJsonObject{{"cells", QJsonArray{heading}}},
            QJsonObject{{"cells", QJsonArray{linked}}},
            QJsonObject{{"cells", QJsonArray{spanning, cell("Rowspan sibling")}}},
            QJsonObject{{"cells", QJsonArray{explicitEmpty}}},
            QJsonObject{{"cells", QJsonArray{cell(QString()), cell("Final sentinel")}}}
        };
        for (const bool collapsed : {true, false}) {
            for (const bool background : {true, false}) {
                QJsonObject style{{"collapse", collapsed ? "collapse" : "separate"}};
                if (background) style.insert("background", "#e9f3ff");
                const QJsonObject table{{"style", style}, {"rows", rows}};
                const QJsonObject entry{{"title", "Ragged table background"}, {"kind", "language"},
                    {"language", window.api_->language()}, {"sections", QJsonArray{
                        QJsonObject{{"level", 2}, {"title", "Table"}, {"blocks", QJsonArray{
                            QJsonObject{{"kind", "table"}, {"table", table}}}}}}}};
                const QByteArray response = QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson();
                window.renderResponse(response, false);
                QCoreApplication::processEvents();
                auto *document = window.reading_->document();
                QTextCursor link = document->find("Linked source");
                QVERIFY(!link.isNull());
                QTextTable *actual = link.currentTable();
                QVERIFY(actual);
                QCOMPARE(actual->rows(), 5);
                QCOMPARE(actual->columns(), 2);
                QCOMPARE(actual->cellAt(0, 0).columnSpan(), 2);
                QCOMPARE(actual->cellAt(0, 1).firstPosition(), actual->cellAt(0, 0).firstPosition());
                QCOMPARE(actual->cellAt(2, 0).rowSpan(), 2);
                QCOMPARE(actual->cellAt(3, 0).firstPosition(), actual->cellAt(2, 0).firstPosition());
                QCOMPARE(actual->format().borderCollapse(), collapsed);
                const QTextTableCell filler = actual->cellAt(1, 1);
                QCOMPARE(filler.row(), 1);
                QCOMPARE(filler.column(), 1);
                QCOMPARE(filler.rowSpan(), 1);
                QCOMPARE(filler.columnSpan(), 1);
                QCOMPARE(filler.firstPosition(), filler.lastPosition());
                QVERIFY(filler.firstCursorPosition().charFormat().anchorNames().isEmpty());
                QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("dict:Slot%20target%23anchor"));
                QCOMPARE(window.currentEntry_, entry);
                const QString plain = document->toPlainText();
                QCOMPARE(plain.count("Two-column table heading"), 1);
                QCOMPARE(plain.count("Linked source"), 1);
                QCOMPARE(plain.count("Rowspan sibling"), 1);
                QCOMPARE(plain.count("Final sentinel"), 1);
                window.reading_->document()->documentLayout()->documentSize();
                const QImage pixels = window.reading_->viewport()->grab().toImage();
                QVERIFY(!pixels.isNull());
                const QString stem = QStringLiteral("ragged-background-%1-%2-%3")
                    .arg(collapsed ? "collapse" : "separate").arg(background ? "blue" : "none")
                    .arg(QCoreApplication::applicationPid());
                // Save before the paint oracle so an expected-red baseline retains evidence.
                QVERIFY(pixels.save(QDir::current().filePath(stem + QStringLiteral(".png"))));
                const qreal dpr = pixels.devicePixelRatio();
                const auto sample = [&](const QTextTableCell &value, const QColor &wanted) {
                    const QRect cursor = window.reading_->cursorRect(value.firstCursorPosition());
                    const QPoint center(cursor.left() + 4, cursor.center().y());
                    if (!window.reading_->viewport()->rect().contains(QRect(center - QPoint(1, 1), QSize(3, 3))))
                        return false;
                    bool equal = true;
                    for (int y = -1; y <= 1; ++y)
                        for (int x = -1; x <= 1; ++x) {
                            const QPoint pixel(qFloor((center.x() + x) * dpr), qFloor((center.y() + y) * dpr));
                            if (!pixels.rect().contains(pixel) || pixels.pixelColor(pixel) != wanted) equal = false;
                        }
                    qInfo() << "RAGGED_BACKGROUND" << stem << value.row() << value.column()
                            << cursor << wanted << pixels.pixelColor(qFloor(center.x() * dpr), qFloor(center.y() * dpr));
                    return equal;
                };
                // The lower blank viewport is the actual reader canvas, independent of theme.
                const QColor canvas = pixels.pixelColor(pixels.width() - 5, pixels.height() - 5);
                const QColor expected = background ? QColor("#e9f3ff") : canvas;
                const bool fillerPainted = sample(filler, expected);
                const bool rowSpanPainted = sample(actual->cellAt(3, 0), QColor("#ffc0cb"));
                const bool explicitPainted = sample(actual->cellAt(3, 1), QColor("#d0ffd0"));
                const bool authoredEmptyPainted = sample(actual->cellAt(4, 0), expected);
                QCOMPARE(actual->cellAt(2, 0).format().background().color(), QColor("#ffc0cb"));
                QCOMPARE(actual->cellAt(3, 1).format().background().color(), QColor("#d0ffd0"));
                if (background) QCOMPARE(filler.format().background().color(), QColor("#e9f3ff"));
                else QCOMPARE(filler.format().background().style(), Qt::NoBrush);
                QVERIFY2(fillerPainted, "Missing source cell must reveal the table background, not a white grid slot");
                QVERIFY(rowSpanPainted);
                QVERIFY(explicitPainted);
                QVERIFY(authoredEmptyPainted);
                window.refreshReading();
                QCOMPARE(window.currentEntry_, entry);
                QCOMPARE(document->toPlainText(), plain);
            }
        }
    }

    void typedTableStylesKeepFractionalMetricsStructureAndDeviceLimit() {
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.readingPointSize_ = 12;
        const auto length = [](double value, const QString &unit = QStringLiteral("px")) {
            return QJsonObject{{"unit", unit}, {"value", value}};
        };
        const auto edges = [](const QJsonObject &value) {
            return QJsonObject{{"top", value}, {"right", value}, {"bottom", value}, {"left", value}};
        };
        const auto cell = [](const QString &label) {
            return QJsonObject{{"spans", QJsonArray{QJsonObject{{"kind", "link"}, {"text", label}, {"target", "Style target"}, {"font_scale", 1.25}}}}};
        };
        const QJsonObject border{{"solid", QJsonObject{{"width", length(0.25)}, {"color", "#aaaaaa"}}}};
        const QJsonObject style{{"background", "#f9f9f9"}, {"border", border}, {"collapse", "collapse"}, {"margins", edges(length(10.5))}};
        QJsonObject header = cell("Styled header"); header.insert("header", true); header.insert("background", "#f2f2f2");
        header.insert("style", QJsonObject{{"border", border}, {"padding", edges(length(0.2, "em"))}, {"text_align", "center"}});
        QJsonObject table{{"style", style}, {"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{header, cell("Sibling")}}}}}};
        QJsonObject plainTable = table; plainTable.remove("style");
        QJsonObject plainHeader = header; plainHeader.remove("style");
        plainTable.insert("rows", QJsonArray{QJsonObject{{"cells", QJsonArray{plainHeader, cell("Sibling")}}}});
        QJsonObject nullStyle = plainTable; nullStyle.insert("style", QJsonValue::Null);
        QCOMPARE(window.tableHtml(plainTable, 0), window.tableHtml(nullStyle, 0));
        QVERIFY(!window.tableHtml(plainTable, 0).contains(SemanticHtml::tableMarkerOpen));
        const QByteArray modelBefore = QJsonDocument(table).toJson(QJsonDocument::Compact);
        for (const int dpi : {96, 144}) {
            QImage device(8, 8, QImage::Format_ARGB32_Premultiplied);
            device.setDotsPerMeterX(qRound(dpi / 0.0254)); device.setDotsPerMeterY(qRound(dpi / 0.0254));
            QTextDocument document; document.setDefaultFont(QFont("DejaVu Sans", 12));
            document.documentLayout()->setPaintDevice(&device);
            // An unstyled table precedes the styled one; ordinal matching may not
            // guess the first frame or the first child span's enlarged font.
            const QString html = window.tableHtml(plainTable, 0) + window.tableHtml(table, 0);
            SemanticHtml::setHtml(&document, html);
            QTextCursor styled = document.find("Styled header"); styled = document.find("Styled header", styled);
            QVERIFY(!styled.isNull()); QTextTable *actual = styled.currentTable(); QVERIFY(actual);
            QCOMPARE(actual->rows(), 1); QCOMPARE(actual->columns(), 2);
            const qreal defaultDpi = QFontMetricsF(QFont()).fontDpi();
            const qreal expectedPadding = 0.2 * 12 * defaultDpi / 72;
            const auto format = actual->cellAt(0, 0).format().toTableCellFormat();
            QVERIFY(qAbs(format.leftPadding() - expectedPadding) < 0.00001);
            QCOMPARE(format.leftBorder(), 0.25);
            QCOMPARE(actual->format().topMargin(), 10.5);
            QVERIFY(actual->format().borderCollapse());
            QCOMPARE(actual->format().background().color(), QColor("#f9f9f9"));
            QCOMPARE(format.background().color(), QColor("#f2f2f2"));
            QCOMPARE(styled.charFormat().anchorHref(), QStringLiteral("dict:Style%20target"));
            QCOMPARE(styled.blockFormat().alignment(), Qt::Alignment(Qt::AlignHCenter));
            QCOMPARE(document.toPlainText().count("Styled header"), 2);
            QVERIFY(!document.toPlainText().contains("wikidict-table-style"));
            const qreal deviceDpi = QFontMetricsF(document.defaultFont(), &device).fontDpi();
            const qreal maximum = 10000 * defaultDpi / deviceDpi;
            QCOMPARE(SemanticHtml::styleLengthUnits(length(0, "em"), &document, 12), 0.0);
            QVERIFY(qAbs(SemanticHtml::styleLengthUnits(length(std::numeric_limits<float>::max(), "em"), &document, 12) - maximum) < 0.00001);
            // Cap is applied through the real qreal table-cell formatter as well.
            QJsonObject hugeHeader = header;
            hugeHeader.insert("style", QJsonObject{{"padding", edges(length(std::numeric_limits<float>::max(), "em"))}});
            QJsonObject huge = table; huge.insert("rows", QJsonArray{QJsonObject{{"cells", QJsonArray{hugeHeader}}}});
            SemanticHtml::setHtml(&document, window.tableHtml(huge, 0));
            QVERIFY(qAbs(document.find("Styled header").currentTable()->cellAt(0, 0).format().toTableCellFormat().leftPadding() - maximum) < 0.00001);
        }
        QCOMPARE(QJsonDocument(table).toJson(QJsonDocument::Compact), modelBefore);
        // Native-valid ragged rows add only implicit empty filler cells in Qt.
        QJsonObject ragged = table;
        ragged.insert("rows", QJsonArray{QJsonObject{{"cells", QJsonArray{header, cell("Second")}}}, QJsonObject{{"cells", QJsonArray{cell("Ragged")}}}});
        QTextDocument raggedDocument; SemanticHtml::setHtml(&raggedDocument, window.tableHtml(ragged, 0));
        QCOMPARE(raggedDocument.find("Ragged").currentTable()->columns(), 2);
        QJsonObject nestedCell{{"spans", QJsonArray{}}, {"blocks", QJsonArray{QJsonObject{{"kind", "table"}, {"table", table}}}}};
        QJsonObject outer{{"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{nestedCell}}}}}};
        QTextDocument nestedDocument;
        SemanticHtml::setHtml(&nestedDocument, window.tableHtml(outer, 0));
        const auto nestedFormat = nestedDocument.find("Styled header").currentTable()->cellAt(0, 0).format().toTableCellFormat();
        QVERIFY(qAbs(nestedFormat.leftPadding() - 0.2 * 12 * QFontMetricsF(QFont()).fontDpi() / 72) < 0.00001);
        QJsonObject reference{{"kind", "note"}, {"number", 4}, {"group_number", 1}, {"spans", QJsonArray{}},
            {"blocks", QJsonArray{QJsonObject{{"kind", "table"}, {"table", table}}}}};
        const QJsonObject entry{{"sections", QJsonArray{}}, {"references", QJsonArray{reference}}};
        QTextDocument referenceDocument; SemanticHtml::setHtml(&referenceDocument, window.entryHtml(entry));
        QCOMPARE(referenceDocument.find("Styled header").currentTable()->format().topMargin(), 10.5);
        QJsonObject noneHeader = header;
        noneHeader.insert("style", QJsonObject{{"border", QJsonObject{{"none", QJsonObject{}}}}, {"padding", edges(length(0))}});
        QJsonObject zeroTable = table; zeroTable.insert("rows", QJsonArray{QJsonObject{{"cells", QJsonArray{noneHeader}}}});
        SemanticHtml::setHtml(&referenceDocument, window.tableHtml(zeroTable, 0));
        const auto zeroFormat = referenceDocument.find("Styled header").currentTable()->cellAt(0, 0).format().toTableCellFormat();
        QCOMPARE(zeroFormat.leftBorder(), 0.0); QCOMPARE(zeroFormat.leftPadding(), 0.0);
        QCOMPARE(zeroFormat.leftBorderStyle(), QTextFrameFormat::BorderStyle_None);
        QJsonObject emptyTable{{"style", style}, {"rows", QJsonArray{}}, {"caption", QJsonArray{
            QJsonObject{{"kind", "link"}, {"text", "Empty table caption"}, {"target", "Caption target"}}}}};
        QTextDocument emptyDocument;
        SemanticHtml::setHtml(&emptyDocument, window.tableHtml(emptyTable, 0) + window.tableHtml(table, 0));
        QVERIFY(emptyDocument.toPlainText().contains("Empty table caption"));
        QCOMPARE(emptyDocument.find("Empty table caption").charFormat().anchorHref(), QStringLiteral("dict:Caption%20target"));
        QCOMPARE(emptyDocument.find("Styled header").currentTable()->format().topMargin(), 10.5);
        emptyTable.insert("rows", QJsonArray{QJsonObject{{"cells", QJsonArray{}}}});
        SemanticHtml::setHtml(&emptyDocument, window.tableHtml(emptyTable, 0) + window.tableHtml(table, 0));
        QCOMPARE(emptyDocument.find("Styled header").currentTable()->format().topMargin(), 10.5);
        // Style metadata cannot silently attach to an unrelated normalized shape.
        const QString corrupt = window.tableHtml(table, 0).replace("colspan='1'", "colspan='2'");
        QVERIFY_EXCEPTION_THROWN(SemanticHtml::setHtml(&raggedDocument, corrupt), std::runtime_error);
    }

    void structuredReferenceBlocksPreserveFurnitureTablesActionsAndLegacyMode() {
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const auto text = [](const QString &value) { return QJsonObject{{"kind", "text"}, {"text", value}}; };
        const auto linked = [](const QString &value, const QString &target) {
            return QJsonObject{{"kind", "link"}, {"text", value}, {"target", target}};
        };
        const QJsonObject legacy{{"number", 7}, {"group_number", 2}, {"name", "source-name"},
            {"group", "alpha"}, {"kind", "note"}, {"spans", QJsonArray{text("Legacy reference")}}};
        const auto entryWith = [](const QJsonObject &reference) {
            return QJsonObject{{"title", "Reference test"}, {"kind", "language"}, {"language", "English"},
                {"sections", QJsonArray{}}, {"references", QJsonArray{reference}}};
        };
        QJsonObject explicitNull = legacy; explicitNull.insert("blocks", QJsonValue::Null);
        QCOMPARE(window.entryHtml(entryWith(legacy)), window.entryHtml(entryWith(explicitNull)));
        QJsonObject reference = legacy;
        reference.insert("spans", QJsonArray{}); reference.insert("blocks", QJsonArray{});
        const QString emptyHtml = window.entryHtml(entryWith(reference));
        QVERIFY(emptyHtml.contains("<div><a name='reference-7'></a>[alpha 2] </div>"));
        QVERIFY(!emptyHtml.contains("Legacy reference"));
        for (const QJsonValue malformed : {QJsonValue(true), QJsonValue(42), QJsonValue("bad")}) {
            QJsonObject bad = reference; bad.insert("blocks", malformed);
            QVERIFY_EXCEPTION_THROWN(window.entryHtml(entryWith(bad)), DictApiError);
        }
        QJsonObject mixed = legacy; mixed.insert("blocks", QJsonArray{});
        QVERIFY_EXCEPTION_THROWN(window.entryHtml(entryWith(mixed)), DictApiError);
        const QStringList headers{"Latinski", "Talijanski", "Njemački", "Hrvatski", "Madžarski"};
        const QStringList forms{"Locuſta", "Locusta", "Heüſchreück", "Szkakavicza", "Saaská"};
        QJsonArray headerCells, formCells;
        for (int i = 0; i < headers.size(); ++i) {
            headerCells.append(QJsonObject{{"header", true}, {"spans", QJsonArray{text(headers[i])}}});
            formCells.append(QJsonObject{{"spans", QJsonArray{linked(forms[i], "Target " + QString::number(i))}}});
        }
        const QJsonObject table{{"rows", QJsonArray{QJsonObject{{"cells", headerCells}}, QJsonObject{{"cells", formCells}}}}};
        const QJsonObject childHeading{{"kind", "heading"}, {"level", 3}, {"anchor", "Compiled_reference_anchor"},
            {"spans", QJsonArray{text("Nested reference heading")}}};
        const QJsonObject nestedCell{{"blocks", QJsonArray{childHeading,
            QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{linked("Nested action", "Nested target")}}}}},
            {"spans", QJsonArray{}}};
        const QJsonObject nestedTable{{"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{nestedCell}}}}}};
        QJsonObject mediaSpan = linked("Owned caption", "cat");
        mediaSpan.insert("classes", "wikidict-media wikidict-media-file-546f6e652e6f6767");
        QJsonObject scaled = text("Scaled reference prose"); scaled.insert("font_scale", 1.25);
        reference.insert("blocks", QJsonArray{
            QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{scaled, linked(" Bibliography", "Bibliography target")}}},
            QJsonObject{{"kind", "table"}, {"table", table}},
            QJsonObject{{"kind", "table"}, {"table", nestedTable}},
            QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{mediaSpan}}}});
        QJsonObject entry = entryWith(reference);
        entry.insert("media", QJsonArray{QJsonObject{{"kind", "audio"}, {"file", "Tone.ogg"}, {"caption", "Owned caption"}}});
        const QString html = window.entryHtml(entry);
        QVERIFY(html.contains("<div><a name='reference-7'></a>[alpha 2] "));
        QVERIFY(!html.contains("<p><table"));
        QVERIFY(html.contains("reference-7-item-0-block-2-row-0-cell-0-block-0"));
        QTextDocument document;
        SemanticHtml::setHtml(&document, html);
        QCOMPARE(document.toPlainText().count("Owned caption"), 1);
        for (const QString &value : headers + forms) QVERIFY(document.toPlainText().contains(value));
        const QTextCursor form = document.find(forms[0]); QVERIFY(!form.isNull());
        QVERIFY(form.currentTable()); QCOMPARE(form.currentTable()->rows(), 2); QCOMPARE(form.currentTable()->columns(), 5);
        QCOMPARE(form.charFormat().anchorHref(), QStringLiteral("dict:Target%200"));
        QCOMPARE(document.find("Nested action").charFormat().anchorHref(), QStringLiteral("dict:Nested%20target"));
        QVERIFY(window.clueFor(entry).contains("Scaled reference prose"));
        QVERIFY(window.clueFor(entry).contains("Locuſta"));
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        QVERIFY(window.reading_->toPlainText().contains("Nested reference heading"));
        QAccessibleInterface *accessible = QAccessible::queryAccessibleInterface(window.reading_);
        QVERIFY(accessible && accessible->textInterface());
        QVERIFY(accessible->textInterface()->text(0, accessible->textInterface()->characterCount()).contains("Locuſta"));
        const QJsonObject beforeJump = window.currentEntry_;
        window.jumpToFragment("Compiled_reference_anchor");
        QCOMPARE(window.currentEntry_, beforeJump);
        const auto wrapTable = [](const QJsonObject &child) {
            return QJsonObject{{"kind", "table"}, {"table", QJsonObject{{"rows", QJsonArray{
                QJsonObject{{"cells", QJsonArray{QJsonObject{{"spans", QJsonArray{}}, {"blocks", QJsonArray{child}}}}}}}}}}};
        };
        QJsonObject deep = QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{text("Depth16 leaf")}}};
        for (int level = 0; level < 16; ++level) deep = wrapTable(deep);
        QJsonObject deepReference = reference; deepReference.insert("blocks", QJsonArray{deep});
        QVERIFY(window.clueFor(entryWith(deepReference)).contains("Depth16 leaf"));
        deepReference.insert("blocks", QJsonArray{wrapTable(deep)});
        QVERIFY_EXCEPTION_THROWN(window.clueFor(entryWith(deepReference)), DictApiError);
        QJsonObject fragment = reference; fragment.insert("kind", "fragment");
        const QString fragmentHtml = window.entryHtml(entryWith(fragment));
        QVERIFY(!fragmentHtml.contains("[alpha 2]"));
        QVERIFY(!fragmentHtml.contains("<a name='reference-7'></a>"));
    }

    void fontScaleRenderLimitUsesDevicePixelsWithoutChangingSemantics() {
        for (const int dpi : {96, 144}) {
            QImage device(8, 8, QImage::Format_ARGB32_Premultiplied);
            device.setDotsPerMeterX(qRound(dpi / 0.0254)); device.setDotsPerMeterY(qRound(dpi / 0.0254));
            QTextDocument document; document.setDefaultFont(QFont("DejaVu Sans", 12));
            document.documentLayout()->setPaintDevice(&device);
            const qreal maximum = SemanticHtml::maximumFontPoints(&document);
            QVERIFY(qAbs(maximum - 10000.0 * 72 / dpi) < 1);
            QCOMPARE(SemanticHtml::boundedFontPoints(12, maximum / 12, maximum), maximum);
            QCOMPARE(SemanticHtml::boundedFontPoints(12, std::numeric_limits<double>::max(), maximum), maximum);
            for (const auto basis : {SemanticHtml::Basis::Context, SemanticHtml::Basis::NormalBody}) {
                const QString html = SemanticHtml::scaledText("<a href=\"dict:Target\">X</a>",
                    std::numeric_limits<float>::max(), "Authored tooltip", basis, 12, false, false, false, 12);
                SemanticHtml::setHtml(&document, html);
                const auto format = document.begin().begin().fragment().charFormat();
                QCOMPARE(format.fontPointSize(), maximum);
                QCOMPARE(format.anchorHref(), QStringLiteral("dict:Target"));
                QCOMPARE(format.toolTip(), QStringLiteral("Authored tooltip"));
                QCOMPARE(document.toPlainText(), QStringLiteral("X"));
            }
            QCOMPARE(SemanticHtml::boundedFontPoints(12, 1.25, maximum), 15.0);
            QVERIFY(qAbs(SemanticHtml::boundedFontPoints(12, 1.25, maximum, 0.8) - 12.0) < 0.0001);
        }
        // Existing helper callers need not provide emitter provenance.
        QTextDocument direct; direct.setDefaultFont(QFont("DejaVu Sans", 12));
        SemanticHtml::setHtml(&direct, SemanticHtml::scaledText("X", 1.25, ""));
        QCOMPARE(direct.begin().begin().fragment().charFormat().fontPointSize(), 15.0);
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        for (const double scale : {double(std::numeric_limits<float>::max()), std::numeric_limits<double>::max()}) {
            const QJsonArray spans{QJsonObject{{"kind", "text"}, {"text", "X"}, {"font_scale", scale}}};
            const QByteArray original = QJsonDocument(spans).toJson(QJsonDocument::Compact);
            const QString html = window.spansHtml(spans);
            QVERIFY(!html.contains(QStringLiteral("inf")));
            QTextDocument rendered; rendered.setDefaultFont(QFont("DejaVu Sans", 12));
            SemanticHtml::setHtml(&rendered, html);
            QVERIFY(rendered.begin().begin().fragment().charFormat().fontPointSize() <= SemanticHtml::maximumFontPoints(&rendered));
            QCOMPARE(QJsonDocument(spans).toJson(QJsonDocument::Compact), original);
        }
        const QString zero = SemanticHtml::scaledText("X", 0, "");
        QVERIFY(!zero.contains(QStringLiteral("context_points")));
        QTextDocument identity; identity.setHtml("<p>X</p>");
        const QString old = identity.toHtml(); SemanticHtml::setHtml(&identity, "<p>X</p>");
        QCOMPARE(identity.toHtml(), old);
    }

    void zeroFontScaleActualHtmlRetainsLogicalTextAcrossReaderSurfaces() {
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QString hidden = QString::fromUcs4(U"سبتمبر\U00013000\U0001f600\u064e");
        const QJsonObject zero{{"kind", "link"}, {"text", hidden}, {"target", "Zero target"},
            {"classes", "AR Egyp"}, {"font_scale", 0}, {"bold", true}, {"italic", true},
            {"underline", true}, {"strike", true}, {"code", true}, {"foreground", "#123456"}};
        const auto text = [](const QString &value) { return QJsonObject{{"kind", "text"}, {"text", value}}; };
        const auto paint = [](QTextDocument *document) {
            QImage image(800, 320, QImage::Format_ARGB32_Premultiplied); image.fill(Qt::white);
            QAbstractTextDocumentLayout::PaintContext context;
            QPainter painter(&image); document->documentLayout()->draw(&painter, context); return image;
        };
        QString diagnosticSurface;
        int diagnosticBase = -1;
        bool diagnosticMixed = false;
        const auto verify = [&](QTextBrowser *browser, const QString &html, const QString &baselineHtml, qreal base, bool alreadyRendered = false) {
            QFont font = browser->document()->defaultFont();
            if (!alreadyRendered) {
                font.setPointSizeF(base); font.setKerning(false);
                browser->setFont(font); browser->document()->setDefaultFont(font);
                SemanticHtml::setHtml(browser, html);
            }
            browser->document()->setTextWidth(700);
            QTextDocument baseline; baseline.setDefaultFont(font);
            baseline.setDocumentMargin(browser->document()->documentMargin());
            baseline.setDefaultTextOption(browser->document()->defaultTextOption());
            SemanticHtml::setHtml(&baseline, baselineHtml); baseline.setTextWidth(700);
            if (diagnosticSurface == QStringLiteral("reference") && !diagnosticMixed) {
                // The visible reference number already keeps this paragraph alive.
                // Removing zero text must preserve its original bidi context, without
                // introducing a U+200B fallback-font line box into the control.
                const QTextCursor original = browser->document()->find(hidden);
                QTextCursor prefix = baseline.find(QStringLiteral("[1]"));
                QVERIFY(!original.isNull()); QVERIFY(!prefix.isNull());
                QTextBlockFormat parent = prefix.blockFormat();
                parent.setLayoutDirection(original.block().textDirection());
                prefix.setBlockFormat(parent);
                QCOMPARE(prefix.block().textDirection(), original.block().textDirection());
            }
            browser->document()->documentLayout()->documentSize(); // Resolve layout before inspecting glyph runs.
            QVERIFY(browser->toPlainText().contains(hidden));
            QTextCursor cursor = browser->document()->find(hidden); QVERIFY(!cursor.isNull());
            QCOMPARE(cursor.selectedText(), hidden); QVERIFY(cursor.charFormat().isAnchor());
            QCOMPARE(cursor.charFormat().anchorHref(), QStringLiteral("dict:Zero%20target"));
            browser->setTextCursor(cursor); browser->copy(); QCOMPARE(QApplication::clipboard()->text(), hidden);
            QAccessibleInterface *accessible = QAccessible::queryAccessibleInterface(browser);
            QVERIFY(accessible && accessible->textInterface());
            const auto accessibleText = accessible->textInterface();
            QVERIFY(accessibleText->text(0, accessibleText->characterCount()).contains(hidden));
            const QTextBlock block = cursor.block();
            const int relative = cursor.selectionStart() - block.position();
            const QTextLine line = block.layout()->lineForTextPosition(relative);
            QVERIFY(line.isValid());
            const qreal diagnosticStart = line.cursorToX(relative);
            const qreal diagnosticEnd = line.cursorToX(relative + hidden.size());
            if (!(qAbs(diagnosticStart - diagnosticEnd) < 0.001) || diagnosticSurface == QStringLiteral("reference")) {
                const QString diagnosticDirectory = QDir::current().filePath(QStringLiteral(".tmp/font-zero-diagnostics/%1").arg(QCoreApplication::applicationPid()));
                QVERIFY(QDir().mkpath(diagnosticDirectory));
                const QString diagnosticStem = QStringLiteral("%1-%2-%3").arg(diagnosticSurface).arg(diagnosticBase).arg(diagnosticMixed ? "mixed" : "whole");
                const QString actualPng = QDir(diagnosticDirectory).filePath(diagnosticStem + QStringLiteral("-actual.png"));
                const QString baselinePng = QDir(diagnosticDirectory).filePath(diagnosticStem + QStringLiteral("-baseline.png"));
                QVERIFY(paint(browser->document()).save(actualPng));
                QVERIFY(paint(&baseline).save(baselinePng));
                qInfo().noquote() << "ZERO_ADVANCE_FRAMES" << actualPng << baselinePng;
                QJsonArray diagnosticRuns;
                for (const QGlyphRun &run : block.layout()->glyphRuns(relative, hidden.size())) {
                    QJsonArray glyphs;
                    const auto ids = run.glyphIndexes(); const auto advances = run.rawFont().advancesForGlyphIndexes(ids);
                    for (int i = 0; i < ids.size(); ++i)
                        glyphs.append(QJsonObject{{"id", int(ids[i])}, {"advance_x", advances[i].x()}, {"advance_y", advances[i].y()}});
                    diagnosticRuns.append(QJsonObject{{"family", run.rawFont().familyName()}, {"rtl", run.isRightToLeft()}, {"glyphs", glyphs}});
                }
                const auto format = cursor.charFormat();
                qInfo().noquote() << "ZERO_ADVANCE_DIAGNOSTIC" << QJsonDocument(QJsonObject{
                    {"surface", diagnosticSurface}, {"base", diagnosticBase}, {"mixed", diagnosticMixed},
                    {"start", diagnosticStart}, {"end", diagnosticEnd}, {"relative", relative},
                    {"line_start", line.textStart()}, {"line_length", line.textLength()},
                    {"start_leading", line.cursorToX(relative, QTextLine::Leading)},
                    {"start_trailing", line.cursorToX(relative, QTextLine::Trailing)},
                    {"end_leading", line.cursorToX(relative + hidden.size(), QTextLine::Leading)},
                    {"end_trailing", line.cursorToX(relative + hidden.size(), QTextLine::Trailing)},
                    {"block_direction", int(block.textDirection())},
                    {"baseline_block_direction", int(baseline.findBlockByNumber(block.blockNumber()).textDirection())},
                    {"no_font_merging", bool(int(format.font().styleStrategy()) & int(QFont::NoFontMerging))},
                    {"family", format.font().family()}, {"weight", int(format.font().weight())},
                    {"background_style", int(format.background().style())}, {"background", format.background().color().name()},
                    {"html_prefix", html.left(1600)}, {"selected_format_html", QTextDocumentFragment(cursor).toHtml().left(1600)}, {"glyph_runs", diagnosticRuns}}).toJson(QJsonDocument::Compact);
            }
            QVERIFY(qAbs(line.cursorToX(relative) - line.cursorToX(relative + hidden.size())) < 0.001);
            bool sawGlyph = false;
            for (const QGlyphRun &run : block.layout()->glyphRuns(relative, hidden.size())) {
                QCOMPARE(run.rawFont().familyName(), QStringLiteral("Wikidict Zero Probe"));
                for (const QPointF &advance : run.rawFont().advancesForGlyphIndexes(run.glyphIndexes()))
                    QCOMPARE(advance, QPointF(0, 0));
                sawGlyph = sawGlyph || !run.glyphIndexes().isEmpty();
            }
            QVERIFY(sawGlyph);
            QCOMPARE(browser->document()->size().height(), baseline.size().height());
            QCOMPARE(paint(browser->document()), paint(&baseline));
        };
        for (const int base : {12, 18}) {
            window.readingPointSize_ = base;
            diagnosticBase = base;
            for (const bool mixed : {true, false}) {
                diagnosticMixed = mixed;
                const QJsonArray source = mixed ? QJsonArray{text("A"), zero, text("B")} : QJsonArray{zero};
                const QJsonArray control = mixed ? QJsonArray{text("AB")} : QJsonArray{text(QString(QChar(0x200b)))};
                const auto verifySurface = [&](const QString &actualHtml, const QString &mixedControlHtml) {
                    QString baselineHtml = mixedControlHtml;
                    if (!mixed) {
                        // Keep the identical production container/furniture, including
                        // <caption>. Truly empty surfaces get an inert parent-font strut;
                        // reference furniture already supplies visible parent text.
                        const QString zeroHtml = window.spansHtml(source);
                        QCOMPARE(actualHtml.count(zeroHtml), 1);
                        baselineHtml = actualHtml;
                        baselineHtml.replace(zeroHtml, diagnosticSurface == QStringLiteral("reference")
                            ? QString() : QString(QChar(0x200b)));
                    }
                    verify(window.reading_, actualHtml, baselineHtml, base);
                };
                const auto paragraph = [&](const QJsonArray &spans) { return window.blockHtml(QJsonObject{{"kind", "paragraph"}, {"spans", spans}}); };
                const auto heading = [&](const QJsonArray &spans) { return window.blockHtml(QJsonObject{{"kind", "heading"}, {"level", 3}, {"spans", spans}}); };
                const auto caption = [&](const QJsonArray &spans) { return window.tableHtml(QJsonObject{{"caption", spans}, {"rows", QJsonArray{}}}, 0); };
                diagnosticSurface = QStringLiteral("paragraph");
                verifySurface(paragraph(source), paragraph(control));
                diagnosticSurface = QStringLiteral("heading");
                verifySurface(heading(source), heading(control));
                diagnosticSurface = QStringLiteral("caption");
                verifySurface(caption(source), caption(control));
                const auto cell = [&](const QJsonArray &spans) {
                    return window.tableHtml(QJsonObject{{"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{QJsonObject{{"spans", spans}}}}}}}}, 0);
                };
                diagnosticSurface = QStringLiteral("cell");
                verifySurface(cell(source), cell(control));
                diagnosticSurface = QStringLiteral("inline");
                verifySurface(window.spansHtml(source), window.spansHtml(control));
                const auto reference = [&](const QJsonArray &spans) {
                    return window.entryHtml(QJsonObject{{"sections", QJsonArray{}}, {"references", QJsonArray{
                        QJsonObject{{"number", 1}, {"group_number", 1}, {"name", "zero"}, {"group", ""}, {"spans", spans}}}}});
                };
                diagnosticSurface = QStringLiteral("reference");
                verifySurface(reference(source), reference(control));
                diagnosticSurface = QStringLiteral("actual-title");
                // Exercise the actual rich display-title HeadingBrowser path.
                QJsonObject entry{{"title", hidden}, {"kind", "language"}, {"language", "Test"},
                    {"display_title", source}, {"sections", QJsonArray{}}};
                window.resize(1180, 780); window.show(); window.activateWindow();
                QTRY_VERIFY(window.isActiveWindow());
                QTRY_VERIFY(!window.compactNavigation_);
                QFont titleFont = window.title_->font(); titleFont.setKerning(false);
                window.title_->setFont(titleFont);
                window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
                QVERIFY(window.title_->accessibleName().contains(hidden));
                QVERIFY(window.title_->height() >= 1);
                verify(window.title_, {}, window.spansHtml(control, 0, {}, {}, window.title_->font().pointSizeF()), window.title_->font().pointSizeF(), true);
                for (const QSize size : {QSize(480, 600), QSize(1180, 780)}) {
                    window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
                    QTextCursor selection(window.title_->document()); selection.setPosition(0);
                    selection.setPosition(1, QTextCursor::KeepAnchor); window.title_->setTextCursor(selection);
                    window.resize(size);
                    QTRY_COMPARE(window.compactNavigation_, size.width() < 720);
                    QTRY_COMPARE(window.title_->font().pointSize(), size.width() < 720 ? 24 : 30);
                    QCOMPARE(window.title_->textCursor().anchor(), 0);
                    QCOMPARE(window.title_->textCursor().position(), 1);
                    QVERIFY(window.reading_->hasFocus());
                    // Inspect the actual resize-triggered result, never serialize
                    // and reimport it (private font strategies do not round-trip).
                    verify(window.title_, {}, window.spansHtml(control, 0, {}, {}, window.title_->font().pointSizeF()), window.title_->font().pointSizeF(), true);
                }
                // Rendering suppression never rewrites the semantic style/link data.
                QCOMPARE(window.currentEntry_.value("display_title").toArray(), source);
                QCOMPARE(source[mixed ? 1 : 0].toObject(), zero);
            }
        }
    }
    void relativeFontScalePreservesContextAndLegacyReductions() {
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const auto span = [](double scale) {
            return QJsonObject{{"kind", "link"}, {"text", QString::fromUtf8("سبتمبر")},
                {"target", QString::fromUtf8("سبتمبر")}, {"trail", "!"}, {"classes", "AR"}, {"font_scale", scale}};
        };
        // Semantic HTML uses the same import/normalization contract as the real
        // widgets; bare Qt setHtml retains overriding legacy size adjustments.
        const auto points = [](const QString &html, int base) {
            QTextDocument document;
            QFont font; font.setPointSize(base); document.setDefaultFont(font);
            SemanticHtml::setHtml(&document, html);
            const QTextCursor cursor = document.find(QString::fromUtf8("سبتمبر"));
            return cursor.isNull() ? -1.0 : cursor.charFormat().font().pointSizeF();
        };
        for (const int base : {12, 18}) {
            window.readingPointSize_ = base;
            const QJsonArray original{span(1)}, enlarged{span(1.25)};
            const qreal bodyPoints = points(window.spansHtml(original), base);
            QVERIFY(bodyPoints > 0);
            QVERIFY(qAbs(points(window.spansHtml(enlarged), base) - bodyPoints * 1.25) < 0.001);
            for (const QString &flag : {QStringLiteral("small"), QStringLiteral("superscript"), QStringLiteral("subscript")}) {
                QJsonObject plain = span(1), large = span(1.25);
                plain.insert(flag, true); large.insert(flag, true);
                QVERIFY(qAbs(points(window.spansHtml(QJsonArray{large}), base) -
                    points(window.spansHtml(QJsonArray{plain}), base) * 1.25) < 0.001);
            }
            QJsonObject nested = span(1.25); nested.insert("small", true); nested.insert("superscript", true);
            QJsonObject nestedIdentity = nested; nestedIdentity.insert("font_scale", 1);
            QVERIFY(qAbs(points(window.spansHtml(QJsonArray{nested}), base) -
                points(window.spansHtml(QJsonArray{nestedIdentity}), base) * 1.25) < 0.001);
            const auto heading = [&](const QJsonArray &spans) {
                return window.blockHtml(QJsonObject{{"kind", "heading"}, {"level", 4}, {"spans", spans}});
            };
            const qreal headingPoints = points(heading(original), base);
            QVERIFY(headingPoints > 0);
            QVERIFY(qAbs(points(heading(enlarged), base) - headingPoints * 1.25) < 0.001);
            const auto caption = [&](const QJsonArray &spans) {
                return window.tableHtml(QJsonObject{{"caption", spans}, {"rows", QJsonArray{}}}, 0);
            };
            const qreal captionPoints = points(caption(original), base);
            QVERIFY(captionPoints > 0);
            QVERIFY(qAbs(points(caption(enlarged), base) - captionPoints * 1.25) < 0.001);
            QTextDocument linked; SemanticHtml::setHtml(&linked, window.spansHtml(enlarged));
            QCOMPARE(linked.toPlainText(), QString::fromUtf8("سبتمبر!"));
            QVERIFY(linked.find(QString::fromUtf8("سبتمبر")).charFormat().isAnchor());
            const QString explanation = QStringLiteral("Original tooltip & \"quoted\"\nline");
            QJsonObject explained = span(1.25);
            explained.insert("explanation", explanation); explained.insert("small", true);
            explained.insert("superscript", true); explained.insert("italic", true);
            const QByteArray payload = QJsonDocument(QJsonObject{{"scale", 1.25}, {"tooltip", explanation}})
                .toJson(QJsonDocument::Compact).toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
            const QString collision = SemanticHtml::scalePrefix + QString::fromLatin1(payload);
            const QJsonObject authored{{"kind", "text"}, {"text", "Authored tooltip"}, {"explanation", collision}};
            QTextDocument annotated;
            QFont annotatedFont; annotatedFont.setPointSize(base); annotated.setDefaultFont(annotatedFont);
            SemanticHtml::setHtml(&annotated, window.spansHtml(QJsonArray{explained, authored}));
            const QTextCharFormat format = annotated.find(QString::fromUtf8("سبتمبر")).charFormat();
            QCOMPARE(format.toolTip(), explanation);
            QCOMPARE(format.anchorHref(), QStringLiteral("dict:%1").arg(QString::fromLatin1(QUrl::toPercentEncoding(QString::fromUtf8("سبتمبر")))));
            QCOMPARE(format.verticalAlignment(), QTextCharFormat::AlignSuperScript);
            QVERIFY(format.fontItalic());
            QVERIFY(!format.hasProperty(QTextFormat::FontSizeAdjustment));
            QCOMPARE(annotated.find(QStringLiteral("!")).charFormat().toolTip(), explanation);
            QCOMPARE(annotated.find(QStringLiteral("Authored tooltip")).charFormat().toolTip(), collision);
            QVERIFY(!annotated.toHtml().contains(QStringLiteral("data-wikidict-font-scale")));

            QJsonObject absent = span(1); absent.remove("font_scale");
            QCOMPARE(window.spansHtml(QJsonArray{absent}), window.spansHtml(original));
            QCOMPARE(heading(QJsonArray{absent}), heading(original));
            QCOMPARE(caption(QJsonArray{absent}), caption(original));
            const auto renderTitle = [&](const QJsonArray &spans) {
                const QJsonObject entry{{"title", QString::fromUtf8("سبتمبر")}, {"kind", "language"},
                    {"language", "Test"}, {"display_title", spans}, {"sections", QJsonArray{}}};
                window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
            };
            // Compare the actual HeadingBrowser against its own unscaled control;
            // title typography follows its responsive widget font, not body points.
            renderTitle(QJsonArray{absent});
            const QString unscaledTitleHtml = window.title_->document()->toHtml();
            const QTextCursor titleControl = window.title_->document()->find(QString::fromUtf8("سبتمبر"));
            QVERIFY(!titleControl.isNull());
            const qreal titlePoints = titleControl.charFormat().font().pointSizeF();
            QVERIFY(titlePoints > 0);
            renderTitle(original);
            QCOMPARE(window.title_->document()->toHtml(), unscaledTitleHtml);
            renderTitle(enlarged);
            const QTextCursor titleScaled = window.title_->document()->find(QString::fromUtf8("سبتمبر"));
            QVERIFY(!titleScaled.isNull());
            QVERIFY(qAbs(titleScaled.charFormat().font().pointSizeF() - titlePoints * 1.25) < 0.001);
            window.resize(1180, 780);
            window.show(); window.activateWindow();
            QTRY_VERIFY(window.isActiveWindow());
            for (const QSize size : {QSize(480, 600), QSize(1180, 780)}) {
                window.reading_->setFocus();
                QTRY_VERIFY(window.reading_->hasFocus());
                QTextCursor selection(window.title_->document());
                selection.setPosition(0); selection.setPosition(1, QTextCursor::KeepAnchor);
                window.title_->setTextCursor(selection);
                window.resize(size);
                QTRY_COMPARE(window.compactNavigation_, size.width() < 720);
                QTRY_VERIFY(window.readerContent_->isVisible());
                QTRY_COMPARE(window.compactReader_, window.readerContent_->width() < 580);
                const QTextCursor resizedScaled = window.title_->document()->find(QString::fromUtf8("سبتمبر"));
                QVERIFY(!resizedScaled.isNull());
                const qreal resizedPoints = resizedScaled.charFormat().font().pointSizeF();
                QCOMPARE(window.title_->textCursor().anchor(), 0);
                QCOMPARE(window.title_->textCursor().position(), 1);
                QVERIFY(window.reading_->hasFocus());
                // Capture the automatically resized scaled output first, then
                // measure an actual unscaled control on that same surface.
                renderTitle(original);
                const QTextCursor resizedControl = window.title_->document()->find(QString::fromUtf8("سبتمبر"));
                QVERIFY(!resizedControl.isNull());
                const qreal controlPoints = resizedControl.charFormat().font().pointSizeF();
                QVERIFY(controlPoints > 0);
                QVERIFY(qAbs(resizedPoints - controlPoints * 1.25) < 0.001);
                const QString identityHtml = window.title_->document()->toHtml();
                renderTitle(QJsonArray{absent});
                QCOMPARE(window.title_->document()->toHtml(), identityHtml);
                renderTitle(enlarged);
            }
        }
    }
    void fontScaleBasisKeepsHeadingOriginAndReadingBaseDistinct() {
        QSettings settings;
        const QString pointKey = QStringLiteral("reader/pointSize");
        const bool hadPointSize = settings.contains(pointKey);
        const QVariant previousPointSize = settings.value(pointKey);
        auto restorePointSize = qScopeGuard([&] {
            if (hadPointSize) settings.setValue(pointKey, previousPointSize); else settings.remove(pointKey);
        });
        MainWindow window(fixture_);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QString label = QStringLiteral("Basis text");
        const auto span = [&](double scale, const QString &basis, int flags = 0) {
            return QJsonObject{{"kind", "link"}, {"text", label}, {"target", "Basis target"},
                {"font_scale", scale}, {"font_scale_basis", basis}, {"small", bool(flags & 1)},
                {"superscript", bool(flags & 2)}, {"subscript", bool(flags & 4)}};
        };
        QString matchedFormatDiagnostic;
        const auto points = [&](const QString &html, qreal base) {
            QTextDocument doc; QFont font; font.setPointSizeF(base); doc.setDefaultFont(font);
            SemanticHtml::setHtml(&doc, html);
            const QTextCursor found = doc.find(label);
            const auto format = found.charFormat();
            matchedFormatDiagnostic = QString::fromUtf8(QJsonDocument(QJsonObject{
                {"found", !found.isNull()}, {"position", found.position()}, {"selected", found.selectedText()},
                {"point_size", format.font().pointSizeF()}, {"raw_point_size", format.fontPointSize()},
                {"has_adjustment", format.hasProperty(QTextFormat::FontSizeAdjustment)},
                {"adjustment", format.intProperty(QTextFormat::FontSizeAdjustment)},
                {"tooltip", format.toolTip()}, {"anchor", format.anchorHref()},
                {"vertical_alignment", int(format.verticalAlignment())}}).toJson(QJsonDocument::Compact));
            return found.isNull() ? -1.0 : found.charFormat().font().pointSizeF();
        };
        const auto block = [&](const QJsonObject &value, int level) {
            return QJsonObject{{"kind", "heading"}, {"level", level}, {"spans", QJsonArray{value}}};
        };
        const auto section = [&](const QJsonObject &value, int level) {
            return window.entryHtml(QJsonObject{{"sections", QJsonArray{QJsonObject{{"level", level}, {"title", label},
                {"blocks", QJsonArray{block(value, level)}}}}}});
        };
        for (const int body : {12, 18}) {
            window.readingPointSize_ = body;
            for (int flags = 0; flags < 8; ++flags) {
                const QJsonObject legacy = span(1, QStringLiteral("context"), flags);
                const qreal bodyControl = points(window.spansHtml(QJsonArray{legacy}), body);
                QVERIFY(bodyControl > 0);
                for (const int level : {1, 2}) for (const double scale : {1.0, 1.2, 1.3}) {
                    const QJsonObject own = span(scale, QStringLiteral("normal_body"), flags);
                    const QJsonObject child = span(scale, QStringLiteral("context"), flags);
                    const qreal headingControl = points(window.blockHtml(block(legacy, level)), body);
                    QVERIFY(headingControl > 0);
                    QVERIFY(qAbs(points(window.blockHtml(block(own, level)), body) - bodyControl * scale) < 0.001);
                    QVERIFY(qAbs(points(window.blockHtml(block(child, level)), body) - headingControl * scale) < 0.001);
                    const QString actualSectionHtml = section(own, level);
                    const qreal actualSectionPoints = points(actualSectionHtml, body);
                    if (!(qAbs(actualSectionPoints - bodyControl * scale) < 0.001))
                        qInfo().noquote() << "SECTION_BASIS_DIAGNOSTIC" << "body" << body << "level" << level
                            << "flags" << flags << "scale" << scale << "basis" << own.value("font_scale_basis").toString()
                            << "actual" << actualSectionPoints << "body_control" << bodyControl
                            << "matched_format" << matchedFormatDiagnostic << "html_prefix" << actualSectionHtml.left(2400);
                    QVERIFY(qAbs(actualSectionPoints - bodyControl * scale) < 0.001);
                    const qreal sectionControl = points(section(legacy, level), body);
                    QVERIFY(sectionControl > 0);
                    QVERIFY(qAbs(points(section(child, level), body) - sectionControl * scale) < 0.001);
                    const QJsonObject table{{"caption", QJsonArray{own}}, {"rows", QJsonArray{}}};
                    QVERIFY(qAbs(points(window.tableHtml(table, 0), body) - bodyControl * scale) < 0.001);
                }
            }
            const auto renderTitle = [&](const QJsonObject &value) {
                const QJsonObject entry{{"title", label}, {"kind", "language"}, {"language", "Test"},
                    {"display_title", QJsonArray{value}}, {"sections", QJsonArray{}}};
                window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
            };
            window.show(); window.activateWindow(); QTRY_VERIFY(window.isActiveWindow());
            for (const QSize size : {QSize(1180, 780), QSize(480, 600)}) {
                window.resize(size); QTRY_COMPARE(window.compactNavigation_, size.width() < 720);
                for (const double scale : {1.0, 1.3}) {
                    renderTitle(span(scale, QStringLiteral("normal_body")));
                    const auto actual = window.title_->document()->find(label).charFormat();
                    QVERIFY(qAbs(actual.font().pointSizeF() - body * scale) < 0.001);
                    QVERIFY(actual.isAnchor());
                    QCOMPARE(actual.anchorHref(), QStringLiteral("dict:Basis%20target"));
                }
                renderTitle(span(1.3, QStringLiteral("normal_body")));
                window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
                QTextCursor selection(window.title_->document()); selection.setPosition(0);
                selection.setPosition(1, QTextCursor::KeepAnchor); window.title_->setTextCursor(selection);
                window.larger_->click();
                QCOMPARE(window.readingPointSize_, body + 1);
                QVERIFY(qAbs(window.title_->document()->find(label).charFormat().font().pointSizeF() - (body + 1) * 1.3) < 0.001);
                QCOMPARE(window.title_->textCursor().anchor(), 0); QCOMPARE(window.title_->textCursor().position(), 1);
                QVERIFY(window.reading_->hasFocus());
                window.smaller_->click(); QCOMPARE(window.readingPointSize_, body);
                QVERIFY(qAbs(window.title_->document()->find(label).charFormat().font().pointSizeF() - body * 1.3) < 0.001);
            }
            QJsonObject bodyIdentity = span(1, QStringLiteral("normal_body"));
            QVERIFY(window.spansHtml(QJsonArray{bodyIdentity}).contains(SemanticHtml::markerOpen));
            QJsonObject bodyZero = span(0, QStringLiteral("normal_body"));
            QVERIFY(window.spansHtml(QJsonArray{bodyZero}).contains(SemanticHtml::markerOpen));
            QVERIFY(window.spansHtml(QJsonArray{bodyZero}).contains(QStringLiteral("Wikidict Zero Probe")));
            for (const QJsonValue invalid : {QJsonValue(QStringLiteral("unknown")), QJsonValue(QJsonValue::Null), QJsonValue(1)}) {
                QJsonObject value = bodyIdentity; value.insert("font_scale_basis", invalid);
                QVERIFY_EXCEPTION_THROWN(window.spansHtml(QJsonArray{value}), DictApiError);
            }
            bodyIdentity.remove("font_scale");
            QVERIFY_EXCEPTION_THROWN(window.spansHtml(QJsonArray{bodyIdentity}), DictApiError);
        }
    }

    void sectionHeadingLayoutWhitespaceDoesNotCreateEmptyReadingBlocks() {
        MainWindow window(QString{});
        const auto text = [](const QString &value) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        QJsonObject linked = text(QStringLiteral("Heading"));
        linked.insert(QStringLiteral("kind"), QStringLiteral("link"));
        linked.insert(QStringLiteral("target"), QStringLiteral("Lexical heading target"));
        const QJsonObject br{{QStringLiteral("kind"), QStringLiteral("line_break")}, {QStringLiteral("text"), QStringLiteral("\n")}};
        const auto paragraph = [](const QJsonArray &spans) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("depth"), 0}, {QStringLiteral("spans"), spans}}; };
        const auto fixture = [&](bool layoutWhitespace) {
            QJsonArray heading{linked};
            if (layoutWhitespace) heading.append(br);
            QJsonArray blocks{QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 2}, {QStringLiteral("spans"), heading}}};
            if (layoutWhitespace) blocks.append(paragraph(QJsonArray{text(QStringLiteral(" "))}));
            blocks.append(paragraph(QJsonArray{text(QStringLiteral("Actual lexical body"))}));
            return QJsonObject{{QStringLiteral("title"), QStringLiteral("Fixture")}, {QStringLiteral("kind"), QStringLiteral("language")},
                {QStringLiteral("language"), QStringLiteral("English")}, {QStringLiteral("sections"), QJsonArray{QJsonObject{
                    {QStringLiteral("level"), 2}, {QStringLiteral("title"), QStringLiteral("Heading")}, {QStringLiteral("blocks"), blocks}}}}};
        };
        const QJsonObject entry = fixture(true), original = entry;
        const QString html = window.entryHtml(entry), control = window.entryHtml(fixture(false));
        QCOMPARE(html, control); // Same lexical content must not gain two layout-only blocks.
        QTextDocument actualDocument, controlDocument;
        actualDocument.setHtml(html); controlDocument.setHtml(control);
        QCOMPARE(actualDocument.blockCount(), controlDocument.blockCount());
        QCOMPARE(actualDocument.toPlainText(), controlDocument.toPlainText());
        QCOMPARE(actualDocument.find(QStringLiteral("Heading")).charFormat().anchorHref(), QStringLiteral("dict:Lexical%20heading%20target"));
        QVERIFY(actualDocument.toPlainText().contains(QStringLiteral("Actual lexical body")));
        QCOMPARE(entry, original);

        QJsonObject second = linked; second.insert(QStringLiteral("text"), QStringLiteral("Second"));
        QJsonObject section{{QStringLiteral("level"), 2}, {QStringLiteral("title"), QStringLiteral("Heading\nSecond")},
            {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")},
                {QStringLiteral("level"), 2}, {QStringLiteral("spans"), QJsonArray{linked, br, second, br}}}}}};
        QJsonObject multiline = fixture(false); multiline.insert(QStringLiteral("sections"), QJsonArray{section});
        const QString multilineHtml = window.entryHtml(multiline);
        QCOMPARE(multilineHtml.count(QStringLiteral("<br>")), 1); // Internal authored line break survives.
        QJsonObject pre{{QStringLiteral("kind"), QStringLiteral("preformatted")}, {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("  "))}}};
        QVERIFY(window.blockHtml(pre).contains(QStringLiteral("<pre>  </pre>")));
        QJsonObject codeSpace = text(QStringLiteral(" ")); codeSpace.insert(QStringLiteral("code"), true);
        QVERIFY(!window.blockHtml(paragraph(QJsonArray{codeSpace})).isEmpty());
        QVERIFY(!window.blockHtml(paragraph(QJsonArray{text(QString(QChar(0x00a0)))})).isEmpty());
        QJsonObject bidiSpace = text(QStringLiteral(" ")); bidiSpace.insert(QStringLiteral("direction"), QStringLiteral("rtl"));
        QVERIFY(!window.blockHtml(paragraph(QJsonArray{bidiSpace})).isEmpty());
        for (const QString &key : {QStringLiteral("list_path"), QStringLiteral("number"), QStringLiteral("level")}) {
            QJsonObject metadata = paragraph(QJsonArray{text(QStringLiteral(" "))});
            metadata.insert(key, key == QStringLiteral("level") ? QJsonValue(3) : QJsonValue(QStringLiteral("retained")));
            QVERIFY2(!window.blockHtml(metadata).isEmpty(), qPrintable(key));
        }
    }

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

    void standardWindowExitHonorsModalAndCloseVetoThenPreservesReaderState_data() {
        QTest::addColumn<int>("standardKey");
        QTest::newRow("standard-close") << int(QKeySequence::Close);
        if (!QKeySequence(QKeySequence::Quit).isEmpty())
            QTest::newRow("standard-quit") << int(QKeySequence::Quit);
    }

    void standardWindowExitHonorsModalAndCloseVetoThenPreservesReaderState() {
        QFETCH(int, standardKey);
        const QKeySequence quit(static_cast<QKeySequence::StandardKey>(standardKey));
        QVERIFY(!quit.isEmpty());
        qInfo() << "Tested standard window exit binding:" << standardKey
                << quit.toString(QKeySequence::PortableText)
                << "platform Quit binding:" << QKeySequence(QKeySequence::Quit).toString(QKeySequence::PortableText);
        const bool oldQuitOnLastWindow = QApplication::quitOnLastWindowClosed();
        const auto restoreQuit = qScopeGuard([oldQuitOnLastWindow] {
            QApplication::setQuitOnLastWindowClosed(oldQuitOnLastWindow);
        });
        QApplication::setQuitOnLastWindowClosed(false);
        struct CloseProbe final : QObject {
            int count = 0;
            bool veto = true;
            bool eventFilter(QObject *watched, QEvent *event) override {
                if (event->type() == QEvent::Close) {
                    ++count;
                    if (veto) {
                        static_cast<QCloseEvent *>(event)->ignore();
                        return true;
                    }
                }
                return QObject::eventFilter(watched, event);
            }
        } probe;
        QByteArray learningBefore;
        QByteArray geometryBefore;
        QByteArray splitterBefore;
        QJsonObject entryBefore;
        QString bodyBefore;
        QString savedKey;
        {
            MainWindow window(fixture_, QStringLiteral("cat"));
            window.resize(900, 700);
            window.show();
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
            QTRY_COMPARE(title(window), QStringLiteral("cat"));
            QVERIFY(window.openWord(QStringLiteral("dog")));
            QVERIFY(window.openWord(QStringLiteral("cat")));
            QTRY_VERIFY(window.bookmark_->isVisible() && window.bookmark_->isEnabled());
            QTest::mouseClick(window.bookmark_, Qt::LeftButton);
            savedKey = window.savedWord(window.currentEntry_).key;
            QVERIFY(window.learning_.isBookmarked(savedKey));
            window.learning_.answer(savedKey, true);
            window.learning_.answer(savedKey, false);
            QSettings learning(QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
            learning.sync();
            learningBefore = learning.value(QStringLiteral("learning/state")).toByteArray();
            entryBefore = window.currentEntry_;
            bodyBefore = window.reading_->toPlainText();
            const QByteArray jsonBefore = window.currentJson_;
            window.installEventFilter(&probe);

            bool modalChecked = false;
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
                QVERIFY(dialog);
                const auto closeDialog = qScopeGuard([dialog] { dialog->reject(); });
                QCOMPARE(dialog->objectName(), QStringLiteral("learningDialog"));
                QTRY_VERIFY(dialog->isVisible());
                QTRY_VERIFY(QApplication::focusWidget()
                    && (QApplication::focusWidget() == dialog
                        || dialog->isAncestorOf(QApplication::focusWidget())));
                QTest::keySequence(QApplication::focusWidget(), quit);
                QCoreApplication::processEvents();
                QCOMPARE(probe.count, 0);
                QCOMPARE(QApplication::activeModalWidget(), dialog);
                QVERIFY(window.isVisible());
                QCOMPARE(window.currentEntry_, entryBefore);
                modalChecked = true;
            });
            window.showLearningDialog(0);
            QVERIFY(modalChecked);

            window.activateWindow();
            window.focusSearch();
            QTRY_COMPARE(QApplication::focusWidget(), window.search_);
            QTest::keySequence(QApplication::focusWidget(), quit);
            QCOMPARE(probe.count, 1);
            QVERIFY(window.isVisible());
            QCOMPARE(window.currentEntry_, entryBefore);
            QCOMPARE(window.currentJson_, jsonBefore);
            QCOMPARE(window.reading_->toPlainText(), bodyBefore);
            QCOMPARE(learning.value(QStringLiteral("learning/state")).toByteArray(), learningBefore);
            geometryBefore = window.saveGeometry();
            splitterBefore = window.readerSplit_->saveState();
            probe.veto = false;
            QTest::keySequence(QApplication::focusWidget(), quit);
            QCOMPARE(probe.count, 2);
            QVERIFY(!window.isVisible());
            QCOMPARE(window.currentEntry_, entryBefore);
        }
        QSettings settings;
        settings.sync();
        QCOMPARE(settings.value(QStringLiteral("reader/root")).toString(), fixture_);
        QCOMPARE(settings.value(QStringLiteral("reader/language")).toString(), QStringLiteral("English"));
        QCOMPARE(settings.value(QStringLiteral("reader/lastKind")).toString(), QStringLiteral("language"));
        QCOMPARE(settings.value(QStringLiteral("reader/lastWord")).toString(), QStringLiteral("cat"));
        QCOMPARE(settings.value(QStringLiteral("reader/windowGeometry")).toByteArray(), geometryBefore);
        QCOMPARE(settings.value(QStringLiteral("reader/splitter")).toByteArray(), splitterBefore);
        QSettings learning(QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
        learning.sync();
        QCOMPARE(learning.value(QStringLiteral("learning/state")).toByteArray(), learningBefore);
        MainWindow reopened{QString()};
        reopened.show();
        QTRY_VERIFY_WITH_TIMEOUT(!reopened.loading_ && reopened.api_, 30000);
        QTRY_COMPARE(title(reopened), QStringLiteral("cat"));
        QCOMPARE(reopened.api_->root(), fixture_);
        QCOMPARE(reopened.currentEntry_, entryBefore);
        QCOMPARE(reopened.reading_->toPlainText(), bodyBefore);
        QVERIFY(reopened.learning_.isBookmarked(savedKey));
        QCOMPARE(reopened.learning_.study().value(savedKey).right, 1);
        QCOMPARE(reopened.learning_.study().value(savedKey).wrong, 1);
        const QJsonObject before = QJsonDocument::fromJson(learningBefore).object();
        const QJsonObject after = QJsonDocument::fromJson(
            learning.value(QStringLiteral("learning/state")).toByteArray()).object();
        for (const QString &key : {QStringLiteral("bookmarks"), QStringLiteral("study"), QStringLiteral("settings")})
            QCOMPARE(after.value(key), before.value(key));
        const QJsonArray historyBefore = before.value(QStringLiteral("history")).toArray();
        const QJsonArray historyAfter = after.value(QStringLiteral("history")).toArray();
        QCOMPARE(historyBefore.size(), 2);
        QCOMPARE(historyAfter.size(), historyBefore.size());
        for (qsizetype i = 0; i < historyBefore.size(); ++i) {
            QJsonObject expected = historyBefore.at(i).toObject();
            const QJsonObject actual = historyAfter.at(i).toObject();
            if (expected.value(QStringLiteral("key")).toString() == savedKey) {
                expected.insert(QStringLiteral("views"), expected.value(QStringLiteral("views")).toInt() + 1);
                QVERIFY(actual.value(QStringLiteral("last_viewed")).toDouble()
                    >= expected.value(QStringLiteral("last_viewed")).toDouble());
                expected.insert(QStringLiteral("last_viewed"), actual.value(QStringLiteral("last_viewed")));
            }
            QCOMPARE(actual, expected);
        }
    }

    void explicitEmptyRootRemainsTheNormalImportDestination() {
        QTemporaryDir empty(QDir::currentPath() + QStringLiteral("/.tmp/explicit-empty-import-XXXXXX"));
        QVERIFY(empty.isValid());
        const QString requested = QDir(empty.path()).absolutePath();
        QSettings().setValue(QStringLiteral("reader/root"), fixture_);
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        MainWindow window(requested);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY(!window.api_);
        QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), requested);
        bool imported = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = static_cast<LibraryDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([dialog] { dialog->done(QDialog::Rejected); });
            QCOMPARE(dialog->selectedRoot(), requested);
            auto *progress = dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"));
            auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
            QVERIFY(progress && status);
            QTRY_VERIFY_WITH_TIMEOUT(!progress->isVisible(), 30000);
            dialog->startImport(fixture_ + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
            QTRY_VERIFY_WITH_TIMEOUT(!progress->isVisible() && status->text().startsWith(QStringLiteral("Installed ")), 30000);
            QVERIFY(dialog->libraryChanged());
            QCOMPARE(dialog->selectedRoot(), requested);
            imported = true;
        });
        window.chooseRoot();
        QVERIFY(imported);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QCOMPARE(QDir(window.api_->root()).absolutePath(), requested);
        QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), requested);
        QVERIFY(QFileInfo::exists(requested + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")));
        QVERIFY(window.openWord(QStringLiteral("cat")));
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
    }

    void unspecifiedEmptyRootDoesNotPersistWorkingDirectory() {
        QVERIFY(!QSettings().contains(QStringLiteral("reader/root")));
        MainWindow window{QString()};
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY(!window.api_);
        QVERIFY(!QSettings().contains(QStringLiteral("reader/root")));
    }

    void emptyLibraryGuidanceDoesNotExposeInternalErrors() {
        QTemporaryDir empty(QDir::currentPath() + QStringLiteral("/.tmp/empty-library-XXXXXX"));
        QVERIFY(empty.isValid());
        MainWindow window(empty.path());
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY(!window.api_);
        QCOMPARE(window.title_->toPlainText(), QStringLiteral("Open your dictionaries"));
        QCOMPARE(window.resultStatus_->text(), QStringLiteral("No dictionary open"));
        const QString guidance = window.reading_->toPlainText();
        QVERIFY(guidance.contains(QStringLiteral("No dictionaries are installed yet.")));
        QVERIFY(!guidance.contains(QStringLiteral("Could not open")));
        QVERIFY(!guidance.contains(QStringLiteral("select:")));
        QVERIFY(!guidance.contains(QStringLiteral("FileNotFound")));
        QVERIFY(!window.search_->isEnabled());
        QVERIFY(!window.results_->isEnabled());
        QVERIFY(!window.kind_->isEnabled());
        QVERIFY(!window.language_->isEnabled());
        auto *library = window.findChild<QPushButton *>(QStringLiteral("openDictionaries"));
        QVERIFY(library && library->isEnabled());
        // Empty-library guidance must not conceal damaged or unrecognized roots.
        for (const QString &problem : {QStringLiteral("missing"), QStringLiteral("unrecognized"),
                QStringLiteral("manifest"), QStringLiteral("missing-language"), QStringLiteral("unfinished"),
                QStringLiteral("raw"), QStringLiteral("compressed"), QStringLiteral("orphan"),
                QStringLiteral("edition"), QStringLiteral("dangling-languages")}) {
            QTemporaryDir rejected(QDir::currentPath() + QStringLiteral("/.tmp/rejected-initial-root-XXXXXX"));
            QVERIFY(rejected.isValid());
            QString path = rejected.path();
            const auto write = [&](const QString &name, const QByteArray &bytes) {
                QFile file(path + QChar('/') + name);
                return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size();
            };
            if (problem == QStringLiteral("missing")) path += QStringLiteral("/missing");
            else if (problem == QStringLiteral("unrecognized")) {
                QVERIFY(write(QStringLiteral("notes.txt"), QByteArrayLiteral("unrecognized folder")));
            } else {
                QVERIFY(write(QStringLiteral("languages.tsv"), problem == QStringLiteral("manifest")
                    ? QByteArrayLiteral("invalid manifest\n") : problem == QStringLiteral("missing-language")
                    ? QByteArrayLiteral("heading\nEnglish\n") : QByteArrayLiteral("heading\n")));
                if (problem == QStringLiteral("unfinished")) QVERIFY(write(QStringLiteral(".incomplete"), {}));
                if (problem == QStringLiteral("raw")) QVERIFY(write(QStringLiteral("supplemental.wikblb"), QByteArrayLiteral("broken")));
                if (problem == QStringLiteral("compressed")) QVERIFY(write(QStringLiteral("supplemental.wikblb.xz"), QByteArrayLiteral("broken")));
                if (problem == QStringLiteral("orphan")) {
                    QVERIFY(QDir(path).mkpath(QStringLiteral("languages")));
                    QVERIFY(write(QStringLiteral("languages/orphan.wikblb"), QByteArrayLiteral("broken")));
                }
                if (problem == QStringLiteral("dangling-languages")) {
                    const QString target = path + QStringLiteral("/removed-languages");
                    QVERIFY(QDir().mkdir(target));
                    QVERIFY(QFile::link(target, path + QStringLiteral("/languages")));
                    QVERIFY(QDir().rmdir(target));
                    QVERIFY(QFileInfo(path + QStringLiteral("/languages")).isSymLink());
                    QVERIFY(!QFileInfo::exists(path + QStringLiteral("/languages")));
                }
                if (problem == QStringLiteral("edition")) QVERIFY(write(QStringLiteral(".desktop-edition"), QByteArrayLiteral("invalid edition")));
            }
            MainWindow failed(path);
            failed.show();
            QTRY_VERIFY_WITH_TIMEOUT(!failed.loading_, 30000);
            QVERIFY(!failed.api_);
            QVERIFY(failed.reading_->toPlainText().contains(QStringLiteral("Could not open this dictionary.")));
            QVERIFY(!failed.reading_->toPlainText().contains(QStringLiteral("No dictionaries are installed yet.")));
            QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), QDir(empty.path()).absolutePath());
        }
        // Synthetic empty-library state, captured before ordinary recovery.
        window.resize(780, 480);
        QCoreApplication::processEvents();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-empty.png")));
        window.openRoot(fixture_, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.search_->isEnabled());
        QVERIFY(window.results_->isEnabled());
    }

    void compactEmptyReadingOpensLibraryByKeyboard() {
        QTemporaryDir empty(QDir::currentPath() + QStringLiteral("/.tmp/empty-library-action-XXXXXX"));
        QVERIFY(empty.isValid());
        const QVariant oldSources = QSettings().value(QStringLiteral("library/catalogSources"));
        const auto restore = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), oldSources); });
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        MainWindow window(empty.path());
        window.resize(640, 600); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        window.showCompactPane(false);
        QVERIFY(window.reading_->isVisible());
        QVERIFY(!window.findChild<QPushButton *>(QStringLiteral("openDictionaries"))->isVisible());
        const QTextCursor link = window.reading_->document()->find(QStringLiteral("Open Library"));
        QVERIFY(!link.isNull()); QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("library:"));
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        QTest::keyClick(window.reading_, Qt::Key_Home, Qt::ControlModifier);
        QTest::keyClick(window.reading_, Qt::Key_Tab);
        bool opened = false;
        QTimer closeDialog;
        connect(&closeDialog, &QTimer::timeout, &window, [&] {
            if (auto *dialog = window.findChild<QDialog *>(QStringLiteral("libraryDialog"))) {
                opened = dialog->isVisible();
                dialog->reject();
            }
        });
        closeDialog.start(20);
        QTest::keyClick(window.reading_, Qt::Key_Return);
        closeDialog.stop();
        QVERIFY(opened);
        QVERIFY(!window.api_);
    }

    void compactNavigationUsesFullWidthAndRetainsWideState() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(1180, 780);
        window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTRY_VERIFY(window.isActiveWindow());
        auto *splitter = window.readerSplit_;
        auto *search = window.search_;
        auto *reader = window.reading_;
        splitter->setSizes({330, 846});
        QCoreApplication::processEvents();
        const QList<int> wideSizes = splitter->sizes();
        QCOMPARE(window.wideSidebarWidth_, wideSizes.value(0));
        const bool bookmarked = window.learning_.isBookmarked(window.savedWord(window.currentEntry_).key);
        const int savedCount = window.learning_.bookmarks().size();
        const QJsonObject entry = window.currentEntry_;
        reader->setFocus();
        QTRY_VERIFY(reader->hasFocus());
        window.resize(480, 600);
        QTRY_VERIFY(window.compactNavigation_);
        QCOMPARE(window.wideSidebarWidth_, wideSizes.value(0));
        QTRY_VERIFY(window.readerContent_->isVisible());
        QVERIFY(!window.searchPane_->isVisible());
        QTRY_VERIFY(reader->viewport()->width() >= 400);
        QCOMPARE(window.width(), 480);
        QWidget *searchSwitch = window.compactToolbar_->widgetForAction(window.searchPaneAction_);
        QWidget *readingSwitch = window.compactToolbar_->widgetForAction(window.readingPaneAction_);
        QCOMPARE(searchSwitch->focusPolicy(), Qt::StrongFocus);
        QCOMPARE(readingSwitch->focusPolicy(), Qt::StrongFocus);
        searchSwitch->setFocus(); QTRY_VERIFY(searchSwitch->hasFocus());
        QTest::keyClick(searchSwitch, Qt::Key_Space);
        QTRY_VERIFY(window.searchPane_->isVisible());
        QVERIFY(!window.readerContent_->isVisible());
        QTRY_VERIFY(search->hasFocus());
        const auto searchGeometry = [&] {
            auto *area = qobject_cast<QScrollArea *>(window.searchPane_);
            return QJsonObject{{"window", window.width()}, {"splitter", splitter->width()},
                {"search_pane", window.searchPane_->width()}, {"viewport", area ? area->viewport()->width() : -1},
                {"sidebar", area && area->widget() ? area->widget()->width() : -1}, {"search", search->width()}};
        };
        qInfo().noquote() << "COMPACT_SEARCH_INITIAL_GEOMETRY" << QJsonDocument(searchGeometry()).toJson(QJsonDocument::Compact);
        QTRY_VERIFY(search->width() >= 400);
        qInfo().noquote() << "COMPACT_SEARCH_SETTLED_GEOMETRY" << QJsonDocument(searchGeometry()).toJson(QJsonDocument::Compact);
        for (const QString &label : {QStringLiteral("Library"), QStringLiteral("History"), QStringLiteral("Saved"), QStringLiteral("Learn"), QStringLiteral("Settings")}) {
            QPushButton *button = nullptr;
            for (auto *candidate : window.searchPane_->findChildren<QPushButton *>())
                if (candidate->text() == label) button = candidate;
            QVERIFY(button && button->isEnabled() && !button->isHidden());
        }
        readingSwitch->setFocus(); QTRY_VERIFY(readingSwitch->hasFocus());
        QTest::keyClick(readingSwitch, Qt::Key_Space);
        QTRY_VERIFY(window.readerContent_->isVisible());
        QTRY_VERIFY(reader->viewport()->width() >= 400);
        search->setText(QStringLiteral("cat"));
        QTest::keyClick(reader, Qt::Key_L, Qt::ControlModifier);
        QTRY_VERIFY(window.searchPane_->isVisible());
        QTRY_VERIFY(search->hasFocus());
        QCOMPARE(search->selectedText(), QStringLiteral("cat"));
        QTest::keyClick(search, Qt::Key_Return);
        QTRY_VERIFY(window.readerContent_->isVisible());
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTRY_VERIFY(reader->hasFocus());
        // Exercise the real focused reader widget, not an action-string oracle.
        QVERIFY(window.clearReadingProjection());
        QCOMPARE(LogicalFlow::inventory(reader->document()), LogicalFlow::Status::Stock);
        reader->setHtml(QStringLiteral("<p>Keyboard page scrolling in the compact reading pane.</p>").repeated(80));
        QTRY_VERIFY(reader->verticalScrollBar()->maximum() > 0);
        reader->verticalScrollBar()->setValue(0);
        QTest::keyClick(reader, Qt::Key_PageDown);
        QTRY_VERIFY(reader->verticalScrollBar()->value() > 0);
        QVERIFY(window.refreshReading());
        // Clicking the already-open suggestion must return to Reading without
        // re-rendering the entry or adding another visit.
        QTest::keyClick(reader, Qt::Key_L, Qt::ControlModifier);
        QTRY_VERIFY(search->hasFocus());
        window.refreshSearch();
        QVERIFY(window.results_->count() > 0);
        const int revisionBefore = reader->document()->revision();
        const qsizetype visitsBefore = window.visits_.size();
        QListWidgetItem *currentSuggestion = window.results_->item(0);
        QCOMPARE(currentSuggestion->data(Qt::UserRole).toString(), QStringLiteral("cat"));
        QTest::mouseClick(window.results_->viewport(), Qt::LeftButton, Qt::NoModifier,
            window.results_->visualItemRect(currentSuggestion).center());
        QTRY_VERIFY(window.readerContent_->isVisible());
        QTRY_VERIFY(reader->hasFocus());
        QCOMPARE(reader->document()->revision(), revisionBefore);
        QCOMPARE(window.visits_.size(), visitsBefore);

        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(window.learning_.bookmarks().size(), savedCount);
        QCOMPARE(window.learning_.isBookmarked(window.savedWord(entry).key), bookmarked);
        // Restoring a search-focused visit must reveal the saved focus target.
        MainWindow::Visit visit; visit.readerFocused = false;
        window.restoreVisitReading(visit);
        QTRY_VERIFY(window.searchPane_->isVisible());
        QTRY_VERIFY(search->hasFocus());
        window.showCompactPane(false);
        QVERIFY(!window.openWord(QStringLiteral("__compact_missing_entry__")));
        QVERIFY(window.searchPane_->isVisible());
        QVERIFY(search->hasFocus());
        QVERIFY(window.resultStatus_->isVisible());
        QVERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(window.openWord(QStringLiteral("cat")));
        QVERIFY(window.readerContent_->isVisible());
        DictApi *previousApi = window.api_.get();
        QTemporaryDir rejected; QVERIFY(rejected.isValid());
        window.loadDataset(rejected.path() + QStringLiteral("/missing"), QStringLiteral("English"), QStringLiteral("language"), false);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QCOMPARE(window.api_.get(), previousApi);
        QVERIFY(window.searchPane_->isVisible());
        QVERIFY(window.resultStatus_->isVisible());
        QVERIFY(window.resultStatus_->text().contains(QStringLiteral("Your current dictionary is still open")));
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(window.openWord(QStringLiteral("cat")));
        QVERIFY(window.readerContent_->isVisible());
        // Tables retain their existing independent horizontal-scroll behavior.
        QVERIFY(window.clearReadingProjection());
        QCOMPARE(LogicalFlow::inventory(reader->document()), LogicalFlow::Status::Stock);
        reader->setHtml(QStringLiteral("<table><tr><td>WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW</td></tr></table>"));
        QTRY_VERIFY(reader->horizontalScrollBar()->maximum() > 0);
        reader->horizontalScrollBar()->setValue(reader->horizontalScrollBar()->maximum());
        QCOMPARE(reader->horizontalScrollBar()->value(), reader->horizontalScrollBar()->maximum());
        qInfo() << "WIDE_CACHE_BEFORE_RETURN" << window.wideSidebarWidth_ << "expected" << wideSizes.value(0);
        QCOMPARE(window.wideSidebarWidth_, wideSizes.value(0));
        window.resize(1000, 780);
        QTRY_VERIFY(!window.compactNavigation_);
        QTRY_VERIFY(window.searchPane_->isVisible() && window.readerContent_->isVisible());
        const auto restoredGeometry = [&] {
            return QJsonObject{{"window", window.width()}, {"splitter", splitter->width()},
                {"sidebar", splitter->sizes().value(0)}, {"reader", splitter->sizes().value(1)},
                {"cached_sidebar", window.wideSidebarWidth_},
                {"expected_sidebar", wideSizes.value(0)}};
        };
        qInfo().noquote() << "WIDE_RESTORE_INITIAL_GEOMETRY" << QJsonDocument(restoredGeometry()).toJson(QJsonDocument::Compact);
        QTRY_VERIFY(qAbs(splitter->sizes().value(0) - wideSizes.value(0)) <= 2);
        qInfo().noquote() << "WIDE_RESTORE_SETTLED_GEOMETRY" << QJsonDocument(restoredGeometry()).toJson(QJsonDocument::Compact);
        QCOMPARE(window.wideSidebarWidth_, wideSizes.value(0));
        QVERIFY(splitter->sizes().value(1) > 600);
        QCOMPARE(window.search_, search); QCOMPARE(window.reading_, reader);
        QCOMPARE(window.currentEntry_, entry);
        QVERIFY(!window.compactToolbar_->isVisible());
        // A compact transition during Saved keeps the sidebar opener reachable.
        QPushButton *saved = nullptr;
        for (auto *button : window.searchPane_->findChildren<QPushButton *>())
            if (button->text() == QStringLiteral("Saved")) saved = button;
        QVERIFY(saved); saved->setFocus(); QTRY_VERIFY(saved->hasFocus());
        bool modalPaneKept = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = window.findChild<QDialog *>(QStringLiteral("learningDialog"));
            if (!dialog) return;
            window.resize(480, 600);
            QCoreApplication::processEvents();
            modalPaneKept = window.compactNavigation_ && window.searchPane_->isVisible() && saved->isVisible();
            dialog->reject();
        });
        saved->click();
        QVERIFY(modalPaneKept);
        QVERIFY(window.searchPane_->isVisible());
        QVERIFY(saved->isVisible());
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(window.learning_.bookmarks().size(), savedCount);
    }

    void compactStartupRetainsOpaqueWideSplitterPreference() {
        QSettings settings;
        const QString geometryKey = QStringLiteral("reader/windowGeometry"), splitterKey = QStringLiteral("reader/splitter");
        const bool hadGeometry = settings.contains(geometryKey), hadSplitter = settings.contains(splitterKey);
        const QVariant originalGeometry = settings.value(geometryKey), originalSplitter = settings.value(splitterKey);
        auto restorePreferences = qScopeGuard([&] {
            if (hadGeometry) settings.setValue(geometryKey, originalGeometry); else settings.remove(geometryKey);
            if (hadSplitter) settings.setValue(splitterKey, originalSplitter); else settings.remove(splitterKey);
        });
        QByteArray wideState, narrowGeometry;
        {
            MainWindow seed(fixture_, QStringLiteral("cat"));
            seed.resize(900, 700); seed.show();
            QTRY_VERIFY_WITH_TIMEOUT(!seed.loading_ && seed.api_, 30000);
            seed.readerSplit_->setSizes({310, 586});
            QCoreApplication::processEvents();
            wideState = seed.readerSplit_->saveState();
            seed.resize(480, 600);
            QTRY_VERIFY(seed.compactNavigation_);
            narrowGeometry = seed.saveGeometry();
        }
        settings.setValue(geometryKey, narrowGeometry);
        settings.setValue(splitterKey, wideState);
        {
            MainWindow restored(fixture_, QStringLiteral("cat"));
            restored.show();
            QTRY_VERIFY_WITH_TIMEOUT(!restored.loading_ && restored.api_, 30000);
            QTRY_VERIFY(restored.compactNavigation_);
            QCOMPARE(restored.width(), 480);
            QCOMPARE(restored.wideSplitterState_, wideState);
            QCOMPARE(restored.wideSidebarWidth_, -1);
            QVERIFY(restored.readerContent_->isVisible());
            QTRY_VERIFY(restored.reading_->viewport()->width() >= 400);
            QCOMPARE(title(restored), QStringLiteral("cat"));
        }
        // A cold compact close must write the identical opaque wide preference.
        QCOMPARE(settings.value(splitterKey).toByteArray(), wideState);
    }

    void narrowReaderKeepsNavigationAndHeadingVisible() {
        MainWindow window{QString()};
        window.title_->setHtml(QStringLiteral("acupuncture"));
        window.resize(480, 540);
        window.show();
        QTRY_VERIFY(window.compactReader_);
        QCOMPARE(window.width(), 480);
        const QRect bounds = window.readerContent_->rect();
        for (auto *widget : std::array<QWidget *, 7>{window.back_, window.forward_, window.sections_, window.smaller_, window.larger_, window.listen_, window.bookmark_}) {
            QVERIFY(widget->isVisible());
            QVERIFY(bounds.contains(QRect(widget->mapTo(window.readerContent_, QPoint()), widget->size())));
            QVERIFY(widget->width() >= widget->minimumSizeHint().width());
        }
        QVERIFY(window.title_->width() >= window.title_->fontMetrics().horizontalAdvance(QStringLiteral("acupuncture")));
        QVERIFY(window.readerHeading_->geometry().bottom() < window.listen_->geometry().top());
        QVERIFY(window.sections_->geometry().top() > window.back_->geometry().bottom());
        auto *back = window.back_;
        auto *sections = window.sections_;
        window.resize(1180, 780);
        QTRY_VERIFY(!window.compactReader_);
        QCOMPARE(window.back_, back);
        QCOMPARE(window.sections_, sections);
        QTRY_VERIFY(window.back_->geometry().top() <= window.sections_->geometry().bottom());
        QTRY_VERIFY(window.sections_->geometry().top() <= window.back_->geometry().bottom());
    }

    void narrowLongTitleKeepsFullWidthAndActionFocus() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(1180, 780); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_VERIFY(window.isActiveWindow());
        const QString exactTitle = QStringLiteral("Appendice:Dictionarios/Germano-interlingua/a");
        const QString href = QStringLiteral("dict:Germano-Interlingua");
        auto *heading = window.readerHeading_;
        auto *titleWidget = window.title_;
        auto *listen = window.listen_;
        auto *bookmark = window.bookmark_;
        int step = 0;
        for (const bool richTitle : {false, true}) {
            QJsonObject entry{{"title", exactTitle}, {"kind", "supplemental"},
                {"sections", QJsonArray{QJsonObject{{"title", "Body"}, {"level", 2},
                    {"blocks", QJsonArray{QJsonObject{{"kind", "paragraph"},
                        {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", "Preserved body."}}}}}}}}}}};
            if (richTitle) entry.insert("display_title", QJsonArray{QJsonObject{
                {"kind", "link"}, {"text", exactTitle}, {"target", "Germano-Interlingua"}}});
            window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
            const QByteArray json = window.currentJson_;
            const QString body = window.reading_->toPlainText();
            const QString bookmarkName = QAccessible::queryAccessibleInterface(bookmark)->text(QAccessible::Name);
            for (const int width : {640, 480, 1180, 640}) {
                QTextCursor selection(titleWidget->document()); selection.setPosition(3);
                selection.setPosition(18, QTextCursor::KeepAnchor); titleWidget->setTextCursor(selection);
                bookmark->setFocus(Qt::TabFocusReason);
                QTRY_VERIFY(bookmark->hasFocus());
                window.resize(width, 600);
                QTRY_COMPARE(window.width(), width);
                QTRY_VERIFY(window.readerContent_->isVisible());
                QTRY_COMPARE(window.compactReader_, window.readerContent_->width() < 580);
                const bool stacked = window.readerContent_->width() < 720;
                QTRY_COMPARE(window.compactHeader_, stacked);
                QTRY_VERIFY(!window.readingFloatLayoutScheduled_);
                QCOMPARE(window.readerHeading_, heading);
                QCOMPARE(window.title_, titleWidget);
                QCOMPARE(window.listen_, listen);
                QCOMPARE(window.bookmark_, bookmark);
                QVERIFY(bookmark->hasFocus());
                QCOMPARE(titleWidget->toPlainText(), exactTitle);
                QCOMPARE(titleWidget->accessibleName(), exactTitle);
                QCOMPARE(QAccessible::queryAccessibleInterface(titleWidget)->text(QAccessible::Name), exactTitle);
                QCOMPARE(QAccessible::queryAccessibleInterface(listen)->text(QAccessible::Name), QStringLiteral("Listen"));
                QCOMPARE(QAccessible::queryAccessibleInterface(bookmark)->text(QAccessible::Name), bookmarkName);
                QCOMPARE(titleWidget->textCursor().anchor(), 3);
                QCOMPARE(titleWidget->textCursor().position(), 18);
                QCOMPARE(titleWidget->font().pointSize(), window.compactReader_ ? 24 : 30);
                const QRect bounds = window.readerContent_->rect();
                for (auto *widget : std::array<QWidget *, 3>{heading, listen, bookmark}) {
                    QVERIFY(widget->isVisible());
                    QVERIFY(bounds.contains(widget->geometry()));
                }
                for (auto *button : {listen, bookmark}) {
                    QVERIFY(button->isEnabled());
                    QVERIFY(button->width() >= button->minimumSizeHint().width());
                }
                if (stacked) {
                    QTRY_VERIFY(heading->geometry().bottom() < listen->geometry().top());
                    QVERIFY(heading->geometry().bottom() < bookmark->geometry().top());
                    QCOMPARE(heading->width(), window.headerLayout_->contentsRect().width());
                } else {
                    QVERIFY(heading->geometry().right() < listen->geometry().left());
                }
                QTRY_VERIFY(titleWidget->viewport()->height() >= qCeil(titleWidget->document()->size().height()));
                QStringList lines;
                for (auto block = titleWidget->document()->begin(); block.isValid(); block = block.next()) {
                    QVERIFY(block.layout());
                    for (int line = 0; line < block.layout()->lineCount(); ++line) {
                        const auto laidOut = block.layout()->lineAt(line);
                        lines.append(block.text().mid(laidOut.textStart(), laidOut.textLength()));
                    }
                    if (richTitle) for (auto it = block.begin(); !it.atEnd(); ++it) {
                        const auto fragment = it.fragment();
                        if (fragment.isValid()) QCOMPARE(fragment.charFormat().anchorHref(), href);
                    }
                }
                if (width == 640) {
                    QVERIFY(stacked && !window.compactReader_);
                    QVERIFY2(std::any_of(lines.cbegin(), lines.cend(), [](const QString &line) {
                        return line.contains(QStringLiteral("Dictionarios"));
                    }), qPrintable(lines.join('|')));
                }
                window.larger_->setFocus(Qt::TabFocusReason);
                QTRY_VERIFY(window.larger_->hasFocus());
                QTest::keyClick(window.larger_, Qt::Key_Tab);
                QTRY_VERIFY(listen->hasFocus());
                QTest::keyClick(listen, Qt::Key_Tab);
                QTRY_VERIFY(bookmark->hasFocus());
                QCOMPARE(window.currentEntry_, entry);
                QCOMPARE(window.currentJson_, json);
                QCOMPARE(window.reading_->toPlainText(), body);
                QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
                const QString frame = QStringLiteral(".tmp/ui-screenshots/desktop-long-title-%1-%2-%3.png")
                    .arg(QCoreApplication::applicationPid()).arg(step++).arg(width);
                QVERIFY(window.grab().save(frame));
                qInfo().noquote() << "LONG_TITLE_LAYOUT" << width << richTitle << lines << frame;
            }
        }
    }

    void learningDialogRetainsKeyboardFocusCue_data() {
        QTest::addColumn<bool>("keyboardOpen");
        QTest::addColumn<bool>("keyboardClose");
        QTest::addColumn<bool>("activateBeforeReturn");
        QTest::newRow("keyboard-close") << true << true << false;
        QTest::newRow("mouse-close") << false << false << false;
        QTest::newRow("mouse-open-keyboard-close") << false << true << false;
        QTest::newRow("keyboard-close-already-active") << true << true << true;
    }

    void learningDialogRetainsKeyboardFocusCue() {
        QFETCH(bool, keyboardOpen);
        QFETCH(bool, keyboardClose);
        QFETCH(bool, activateBeforeReturn);
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(1000, 700);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.activateWindow();
        window.search_->setFocus(Qt::MouseFocusReason);
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        QPushButton *saved = nullptr;
        for (auto *button : window.searchPane_->findChildren<QPushButton *>())
            if (button->text() == QStringLiteral("Saved")) saved = button;
        QVERIFY(saved && saved->isVisible());
        const QByteArray entryBefore = window.currentJson_;
        const QString queryBefore = window.search_->text();
        const auto historyKeys = [&] {
            QStringList keys;
            for (const SavedWord &word : window.learning_.history()) keys.append(word.key);
            return keys;
        };
        const QStringList historyBefore = historyKeys();
        if (keyboardOpen) {
            for (int step = 0; step < 32 && QApplication::focusWidget() != saved; ++step) {
                QWidget *focused = QApplication::focusWidget(); QVERIFY(focused);
                QTest::keyClick(focused, Qt::Key_Tab);
            }
            QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(saved));
            QStyleOption before;
            before.initFrom(saved);
            QVERIFY(before.state.testFlag(QStyle::State_KeyboardFocusChange));
        }
        bool closed = false;
        QTimer::singleShot(0, &window, [&] {
            QPointer<QDialog> dialog = window.findChild<QDialog *>(QStringLiteral("learningDialog"));
            auto cleanup = qScopeGuard([&] { if (dialog && dialog->isVisible()) dialog->reject(); });
            QVERIFY(dialog && dialog == QApplication::activeModalWidget());
            auto *tabs = dialog->findChild<QTabWidget *>(QStringLiteral("learningDialogTabs"));
            auto *box = dialog->findChild<QDialogButtonBox *>(QStringLiteral("learningDialogButtons"));
            QVERIFY(tabs && box);
            QPushButton *close = box->button(QDialogButtonBox::Close); QVERIFY(close);
            if (keyboardClose) {
                QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(tabs->tabBar()));
                QTest::keyClick(tabs->tabBar(), Qt::Key_Tab, Qt::ShiftModifier);
                QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(close));
                QTest::keyClick(close, Qt::Key_Space);
            } else {
                QTest::mouseClick(close, Qt::LeftButton);
            }
            QVERIFY(!dialog->isVisible());
            if (activateBeforeReturn) {
                window.activateWindow();
                QTRY_VERIFY(window.isActiveWindow());
                QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(saved));
            }
            closed = true;
        });
        if (keyboardOpen) QTest::keyClick(saved, Qt::Key_Space);
        else QTest::mouseClick(saved, Qt::LeftButton);
        QVERIFY(closed);
        // Check the remembered opener immediately after the modal returns,
        // then check again after any deferred parent-window activation.
        QCOMPARE(window.focusWidget(), static_cast<QWidget *>(saved));
        QStyleOption returned;
        returned.initFrom(saved);
        QCOMPARE(returned.state.testFlag(QStyle::State_KeyboardFocusChange), keyboardOpen || keyboardClose);
        // A real compositor can reactivate the parent after exec returns. The
        // offscreen platform needs that normal Qt activation supplied explicitly;
        // do not repair child focus or set the cue in the fixture.
        qInfo() << "FOCUS_CUE_PARENT_ACTIVE_AFTER_EXEC" << window.isActiveWindow();
        if (QGuiApplication::platformName() == QStringLiteral("offscreen") && !window.isActiveWindow())
            QTimer::singleShot(0, &window, [&window] { window.activateWindow(); });
        QTRY_VERIFY(window.isActiveWindow());
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(saved));
        QStyleOption activated;
        activated.initFrom(saved);
        QCOMPARE(activated.state.testFlag(QStyle::State_KeyboardFocusChange), keyboardOpen || keyboardClose);
        if (activateBeforeReturn) {
            // A click which keeps child focus must not leave a stale token to
            // restore a keyboard cue on an unrelated later activation.
            QVERIFY(window.meta_->isVisible());
            QCOMPARE(window.meta_->focusPolicy(), Qt::NoFocus);
            QTest::mouseClick(window.meta_, Qt::LeftButton);
            QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(saved));
            QWidget other;
            other.show();
            other.activateWindow();
            QTRY_VERIFY(other.isActiveWindow());
            window.activateWindow();
            QTRY_VERIFY(window.isActiveWindow());
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(saved));
            QStyleOption reactivated;
            reactivated.initFrom(saved);
            QVERIFY(!reactivated.state.testFlag(QStyle::State_KeyboardFocusChange));
        }
        // A subsequent genuine mouse focus change must cancel any pending cue.
        QTest::mouseClick(window.search_, Qt::LeftButton);
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        QStyleOption mouseFocused;
        mouseFocused.initFrom(window.search_);
        QVERIFY(!mouseFocused.state.testFlag(QStyle::State_KeyboardFocusChange));
        QCOMPARE(window.currentJson_, entryBefore);
        QCOMPARE(window.search_->text(), queryBefore);
        QCOMPARE(historyKeys(), historyBefore);
    }

    void learningDialogTracksNarrowAvailableGeometry() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.bookmark_->click();
        const QByteArray entryBefore = window.currentJson_;
        const auto keys = [](const QVector<SavedWord> &words) {
            QStringList values; for (const SavedWord &word : words) values.append(word.key); return values;
        };
        const QStringList historyBefore = keys(window.learning_.history());
        const QStringList bookmarksBefore = keys(window.learning_.bookmarks());
        window.activateWindow(); window.search_->setFocus();
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            QPointer<QDialog> dialog = window.findChild<QDialog *>(QStringLiteral("learningDialog"));
            if (!dialog) dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QPointer<QScreen> screen;
            QRect original;
            // Install rejection before any assertion that can end this callback.
            auto cleanup = qScopeGuard([&] {
                if (screen && original.isValid())
                    QMetaObject::invokeMethod(screen.data(), "availableGeometryChanged", Qt::DirectConnection, Q_ARG(QRect, original));
                if (dialog && dialog->isVisible()) dialog->reject();
            });
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("learningDialog"));
            QCOMPARE(QApplication::activeModalWidget(), static_cast<QWidget *>(dialog.data()));
            screen = dialog->screen(); QVERIFY(screen);
            original = screen->availableGeometry();
            // Let the production post-show decoration/placement adjustment finish.
            QCoreApplication::processEvents();
            auto *tabs = dialog->findChild<QTabWidget *>(QStringLiteral("learningDialogTabs"));
            auto *box = dialog->findChild<QDialogButtonBox *>(QStringLiteral("learningDialogButtons"));
            QVERIFY(tabs && box);
            auto *close = box->button(QDialogButtonBox::Close); QVERIFY(close);
            const QRect narrow(original.topLeft(), QSize(480, 600));
            const auto announce = [&](const QRect &available) {
                return QMetaObject::invokeMethod(screen.data(), "availableGeometryChanged", Qt::DirectConnection, Q_ARG(QRect, available));
            };
            QVERIFY(announce(narrow));
            QTRY_VERIFY(narrow.contains(dialog->frameGeometry()));
            for (int page = 0; page < tabs->count(); ++page) {
                tabs->setCurrentIndex(page); QCoreApplication::processEvents();
                QVERIFY(narrow.contains(dialog->frameGeometry()));
                QVERIFY(close->isVisible() && close->isEnabled());
                QVERIFY(narrow.contains(QRect(close->mapToGlobal(QPoint()), close->size())));
                auto *accessible = QAccessible::queryAccessibleInterface(close); QVERIFY(accessible);
                QVERIFY(!accessible->state().invisible); QVERIFY(narrow.contains(accessible->rect()));
            }
            // The same open dialog must also follow a wide-to-narrow display change.
            const QRect wide(original.topLeft(), QSize(760, 600));
            QVERIFY(announce(wide)); dialog->resize(720, 550);
            QVERIFY(dialog->width() > 480);
            QVERIFY(announce(narrow)); QTRY_VERIFY(narrow.contains(dialog->frameGeometry()));
            auto *handle = dialog->windowHandle(); QVERIFY(handle);
            QScreen *reportedScreen = handle->screen();
            QVERIFY(reportedScreen == screen.data());
            // Controlled signal delivery tests rebinding; it does not change
            // QWindow/QScreen state or stand in for a real monitor move.
            QVERIFY(QMetaObject::invokeMethod(handle, "screenChanged", Qt::DirectConnection,
                Q_ARG(QScreen *, reportedScreen)));
            QCOMPARE(handle->screen(), reportedScreen);
            const int frameWidth = qMax(0, dialog->frameGeometry().width() - dialog->width());
            QCOMPARE(dialog->maximumWidth(), qMax(1, original.width() - frameWidth));
            if (original.width() - frameWidth > 480) {
                dialog->resize(qMin(720, original.width() - frameWidth), 550);
                QVERIFY(dialog->width() > 480);
            }
            QVERIFY(announce(narrow)); QTRY_VERIFY(narrow.contains(dialog->frameGeometry()));
            tabs->setCurrentIndex(3);
            auto *settingsScroll = qobject_cast<QScrollArea *>(tabs->currentWidget()); QVERIFY(settingsScroll);
            auto *limit = settingsScroll->findChild<QSpinBox *>(QStringLiteral("learningHistoryLimit")); QVERIFY(limit);
            limit->setValue(47); QCOMPARE(window.learning_.settings().historyLimit, 47);
            limit->setFocus(Qt::TabFocusReason);
            QTRY_VERIFY(QApplication::focusWidget() == limit || limit->isAncestorOf(QApplication::focusWidget()));
            for (int step = 0; step < 48 && QApplication::focusWidget() != close; ++step) {
                QWidget *focused = QApplication::focusWidget(); QVERIFY(focused);
                QTest::keyClick(focused, Qt::Key_Tab); QCoreApplication::processEvents();
            }
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(close));
            QVERIFY(narrow.contains(QRect(close->mapToGlobal(QPoint()), close->size())));
            QTest::keyClick(close, Qt::Key_Space);
            QVERIFY(!dialog->isVisible());
            exercised = true;
        });
        window.showLearningDialog(1);
        QVERIFY(exercised);
        // Keep the remembered-child oracle before any fixture activation. The
        // offscreen plugin has no window manager to reactivate a parent when
        // its modal child hides; do not repair the child focus to make it pass.
        QCOMPARE(window.focusWidget(), static_cast<QWidget *>(window.search_));
        if (QGuiApplication::platformName() == QStringLiteral("offscreen") && !window.isActiveWindow())
            window.activateWindow();
        QTRY_VERIFY(window.isActiveWindow());
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        QCOMPARE(window.currentJson_, entryBefore);
        QCOMPARE(keys(window.learning_.history()), historyBefore);
        QCOMPARE(keys(window.learning_.bookmarks()), bookmarksBefore);
        QCOMPARE(window.learning_.settings().historyLimit, 47);
    }

    void richLongTitleWrapsWithoutAddingKeyboardStop() {
        MainWindow window{QString()};
        const QString title = QStringLiteral("StyledHeadingWitnessStyledHeadingWitnessStyledHeadingWitness");
        window.title_->setHtml(QStringLiteral("<b><i title='title explanation'>%1</i></b>").arg(title));
        window.resize(900, 700);
        window.show();
        QTRY_COMPARE(window.title_->accessibleName(), title);
        QVERIFY(!(window.title_->focusPolicy() & Qt::TabFocus));
        QCOMPARE(window.title_->focusPolicy(), Qt::ClickFocus);
        QVERIFY(window.title_->textInteractionFlags().testFlag(Qt::TextSelectableByMouse));
        QVERIFY(!window.title_->openLinks());
        QVERIFY(!window.title_->openExternalLinks());
        for (const int width : {900, 640}) {
            window.resize(width, 700);
            QTRY_VERIFY(window.title_->document()->size().height() <= window.title_->viewport()->height() + 1);
            QVERIFY(window.title_->document()->idealWidth() <= window.title_->viewport()->width() + 1);
            const QTextCursor text = window.title_->document()->find(title);
            QVERIFY(!text.isNull());
            QVERIFY(text.charFormat().fontItalic());
            QVERIFY(text.charFormat().fontWeight() >= QFont::Bold);
            QCOMPARE(text.charFormat().toolTip(), QStringLiteral("title explanation"));
            window.title_->setTextCursor(text);
            QCOMPARE(window.title_->textCursor().selectedText(), title);
        }
    }

    void localizedDefaultFoldingUsesCompiledEtymologyAndRetainsExplicitUnfold() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const auto previous = window.learning_.settings();
        auto restore = qScopeGuard([&] {
            window.learning_.setCollapseEtymology(previous.collapseEtymology);
            window.learning_.setCollapsePronunciation(previous.collapsePronunciation);
        });
        window.learning_.setCollapseEtymology(true);
        window.learning_.setCollapsePronunciation(true);
        auto section = [](const QString &heading, const QString &body) {
            const QJsonArray spans{QJsonObject{{"kind", "text"}, {"text", body}}};
            const QJsonArray blocks{QJsonObject{{"kind", "paragraph"}, {"spans", spans}}};
            return QJsonObject{{"title", heading}, {"level", 3}, {"blocks", blocks}};
        };
        // Synthetic control uses the retained Portuguese botar section labels
        // and compiled etymology relation, without claiming a new corpus fixture.
        QJsonObject entry = window.currentEntry_;
        entry.insert(QStringLiteral("sections"), QJsonArray{
            section(QStringLiteral("Portugués"), QStringLiteral("owner body")),
            section(QStringLiteral("Etimologia"), QStringLiteral("etymology body witness")),
            section(QStringLiteral("Prononciacion"), QStringLiteral("pronunciation body witness")),
            section(QStringLiteral("Forma de vèrb"), QStringLiteral("definition body witness"))});
        entry.insert(QStringLiteral("organization"), QJsonObject{{"lexemes", QJsonArray{
            QJsonObject{{"section", 3}, {"etymology", 1}}}}});
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson(), false);
        QCOMPARE(window.collapsedSections_, (QSet<int>{1, 2}));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("etymology body witness")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("pronunciation body witness")));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("definition body witness")));

        // Explicit navigation unfolds this entry without changing its defaults.
        window.jumpToSection(1);
        QCOMPARE(window.collapsedSections_, (QSet<int>{2}));
        window.refreshReading();
        QCOMPARE(window.collapsedSections_, (QSet<int>{2}));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("etymology body witness")));
        QVERIFY(window.learning_.settings().collapseEtymology);
        QVERIFY(window.learning_.settings().collapsePronunciation);

        window.learning_.setCollapseEtymology(false);
        window.resetFolding();
        QCOMPARE(window.collapsedSections_, (QSet<int>{2}));
        window.learning_.setCollapsePronunciation(false);
        window.resetFolding();
        QVERIFY(window.collapsedSections_.isEmpty());
        window.learning_.setCollapseEtymology(true);
        window.resetFolding();
        QCOMPARE(window.collapsedSections_, (QSet<int>{1}));

        // Semantic identity works independently of the displayed translation.
        auto sections = window.currentEntry_.value(QStringLiteral("sections")).toArray();
        auto translated = sections[1].toObject();
        translated.insert(QStringLiteral("title"), QStringLiteral("Origin in another source language"));
        sections[1] = translated;
        window.currentEntry_.insert(QStringLiteral("sections"), sections);
        window.resetFolding();
        QCOMPARE(window.collapsedSections_, (QSet<int>{1}));

        // Null/missing/out-of-range indices must not accidentally fold section0.
        window.currentEntry_.insert(QStringLiteral("organization"), QJsonObject{{"lexemes", QJsonArray{
            QJsonObject{}, QJsonObject{{"etymology", QJsonValue::Null}},
            QJsonObject{{"etymology", -1}}, QJsonObject{{"etymology", 99}}}}});
        window.resetFolding();
        QVERIFY(window.collapsedSections_.isEmpty());

        // Existing English numbered headings remain compatible; unrelated
        // headings are not matched by a guessed localized prefix.
        window.learning_.setCollapsePronunciation(true);
        window.currentEntry_.insert(QStringLiteral("sections"), QJsonArray{
            section(QStringLiteral("Etymology 2"), QStringLiteral("english etymology")),
            section(QStringLiteral("Pronunciation 2"), QStringLiteral("english pronunciation")),
            section(QStringLiteral("Prononciacion examples"), QStringLiteral("unrelated body"))});
        window.currentEntry_.insert(QStringLiteral("organization"), QJsonObject{});
        window.resetFolding();
        QCOMPARE(window.collapsedSections_, (QSet<int>{0, 1}));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("unrelated body")));
    }
    void keyboardFoldRetainsItsActivationAnchor() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.learning_.setCollapseEtymology(false);
        window.resize(900, 700);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const auto selectedAnchor = [&] {
            QTextCursor selected = window.reading_->textCursor();
            if (!selected.hasSelection()) return QUrl();
            selected.setPosition(selected.selectionStart());
            selected.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            return QUrl(selected.charFormat().anchorHref());
        };
        window.search_->setFocus();
        QTRY_VERIFY(window.search_->hasFocus());
        window.reading_->setFocus(Qt::TabFocusReason);
        QTRY_VERIFY(window.reading_->hasFocus());
        int anchorFragments = 0;
        bool sectionAnchorPresent = false;
        for (auto block = window.reading_->document()->begin(); block.isValid(); block = block.next()) {
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const QString href = it.fragment().charFormat().anchorHref();
                if (href.isEmpty()) continue;
                ++anchorFragments;
                sectionAnchorPresent |= QUrl(href).scheme() == QStringLiteral("section");
            }
        }
        QVERIFY(sectionAnchorPresent);
        QVERIFY(window.collapsedSections_.isEmpty());
        QStringList traversed;
        for (int i = 0; i <= anchorFragments && selectedAnchor().scheme() != QStringLiteral("section"); ++i) {
            QTest::keyClick(window.reading_, Qt::Key_Tab);
            traversed.append(selectedAnchor().toString());
        }
        QVERIFY2(selectedAnchor().scheme() == QStringLiteral("section"), qPrintable(traversed.join(QStringLiteral(", "))));
        const QUrl anchor = selectedAnchor();
        QTest::keyClick(window.reading_, Qt::Key_Return);
        QTRY_VERIFY(!window.collapsedSections_.isEmpty());
        const auto collapsed = window.collapsedSections_;
        QTRY_COMPARE(selectedAnchor(), anchor);
        QTest::keyClick(window.reading_, Qt::Key_Return);
        QTRY_VERIFY(window.collapsedSections_.isEmpty());
        QTRY_COMPARE(selectedAnchor(), anchor);
        QTest::keyClick(window.reading_, Qt::Key_Return);
        QTRY_COMPARE(window.collapsedSections_, collapsed);
    }

    void narrowTablesKeepWordsAndScrollHorizontally() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QString coptic = QString::fromUtf8("ϥⲱϭⲉ");
        QJsonArray rows;
        for (const QString &word : {QStringLiteral("present"), coptic}) {
            QJsonArray cells;
            for (int column = 0; column < 12; ++column)
                cells.append(QJsonObject{{QStringLiteral("spans"), QJsonArray{
                    QJsonObject{{QStringLiteral("text"), word}}}}});
            rows.append(QJsonObject{{QStringLiteral("cells"), cells}});
        }
        window.reading_->setHtml(window.tableHtml(QJsonObject{{QStringLiteral("rows"), rows}}, 0));
        QTextDocument *document = window.reading_->document();
        document->documentLayout()->documentSize();
        QTextTable *table = nullptr;
        for (QTextFrame *frame : document->rootFrame()->childFrames())
            if (auto *candidate = qobject_cast<QTextTable *>(frame)) { table = candidate; break; }
        QVERIFY(table);
        QCOMPARE(table->columns(), 12);
        QCOMPARE(table->rows(), 2);
        for (int row = 0; row < 2; ++row) {
            for (int column = 0; column < 12; ++column) {
                const QTextBlock block = table->cellAt(row, column).firstCursorPosition().block();
                QCOMPARE(block.text(), row == 0 ? QStringLiteral("present") : coptic);
                QCOMPARE(block.layout()->lineCount(), 1);
            }
        }
        QTRY_VERIFY(window.reading_->horizontalScrollBar()->maximum() >
                    window.reading_->viewport()->width() / 4);
        // Ordinary prose still wraps at spaces instead of becoming one unbounded line.
        window.reading_->setHtml(QStringLiteral("<p>") + QStringLiteral("ordinary prose ").repeated(80) + QStringLiteral("</p>"));
        document->documentLayout()->documentSize();
        QVERIFY(document->begin().layout()->lineCount() > 1);
        QTRY_COMPARE(window.reading_->horizontalScrollBar()->maximum(), 0);
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

    void egyptianSpansShapeGroupsAndKeepNavigation() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QString joined = QString::fromUtf8("𓂜𓐰𓏏𓐱𓏭𓅪𓆑");
        const QString unjoined = QString::fromUtf8("𓂜𓏏𓏭𓅪𓆑");
        const QJsonArray spans{
            QJsonObject{{QStringLiteral("text"), QStringLiteral("before ")}},
            QJsonObject{{QStringLiteral("text"), joined},
                        {QStringLiteral("classes"), QStringLiteral("example Egyp")},
                        {QStringLiteral("language"), QStringLiteral("egy")},
                        {QStringLiteral("direction"), QStringLiteral("ltr")}},
            QJsonObject{{QStringLiteral("text"), QStringLiteral("next")},
                        {QStringLiteral("kind"), QStringLiteral("link")},
                        {QStringLiteral("target"), QStringLiteral("jwtj-n.f")}},
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" after")}}
        };
        window.collapsedSections_.clear(); // Render the diagnostic Noun independent of fixture fold defaults.
        for (const bool actualHeadword : {false, true}) {
            QJsonArray renderedSpans = spans;
            if (actualHeadword) {
                QJsonObject headword = renderedSpans.at(1).toObject();
                headword.insert(QStringLiteral("classes"), QStringLiteral("headword-line None headword Egyp"));
                headword.insert(QStringLiteral("bold"), true);
                headword.insert(QStringLiteral("role"), QStringLiteral("headword"));
                renderedSpans.replace(1, headword);
            }
            const QJsonObject section{{QStringLiteral("title"), QStringLiteral("Noun")},
                {QStringLiteral("level"), 3},
                {QStringLiteral("blocks"), QJsonArray{QJsonObject{
                    {QStringLiteral("kind"), QStringLiteral("paragraph")},
                    {QStringLiteral("spans"), renderedSpans}}}}};
            const QString html = actualHeadword
                ? window.entryHtml(QJsonObject{{QStringLiteral("sections"), QJsonArray{section}}})
                : window.spansHtml(renderedSpans);
            window.reading_->setHtml(html);
            QTextDocument *document = window.reading_->document();
            document->setTextWidth(1000);
            document->documentLayout()->documentSize();
            const QTextCursor signs = document->find(joined);
            QVERIFY(!signs.isNull());
            QCOMPARE(signs.selectedText(), joined);
            const QFont font = signs.charFormat().font();
            QVERIFY(font.families().contains(QStringLiteral("NewGardinerOmni")));
            QVERIFY(!document->find(QStringLiteral("before")).charFormat().font().families()
                         .contains(QStringLiteral("NewGardinerOmni")));
            QCOMPARE(document->find(QStringLiteral("next")).charFormat().anchorHref(),
                     QStringLiteral("dict:jwtj-n.f"));

            // The authored jwtj.f sequence stacks D35 over the horizontal t/y pair.
            // Verify Qt's actual font shaping, not just retained Unicode controls.
            const QFontMetricsF metrics(font);
            QVERIFY(metrics.horizontalAdvance(joined) + 1 < metrics.horizontalAdvance(unjoined));
            const QTextBlock block = signs.block();
            QList<QRectF> ink;
            for (const QGlyphRun &run : block.layout()->glyphRuns(
                     signs.selectionStart() - block.position(), joined.size())) {
                QCOMPARE(run.rawFont().familyName(), QStringLiteral("NewGardinerOmni"));
                const auto indexes = run.glyphIndexes();
                const auto positions = run.positions();
                QCOMPARE(indexes.size(), positions.size());
                for (qsizetype i = 0; i < indexes.size(); ++i) {
                    const QRectF bounds = run.rawFont().pathForGlyph(indexes[i]).boundingRect().translated(positions[i]);
                    if (bounds.isEmpty()) continue;
                    QVERIFY(indexes[i] != 0);
                    ink.append(bounds);
                }
            }
            QCOMPARE(ink.size(), qsizetype(5));
            QVERIFY(ink[0].bottom() < ink[1].top());
            QVERIFY(ink[0].bottom() < ink[2].top());
            QVERIFY(ink[1].right() < ink[2].left());
            QVERIFY(ink[3].left() > ink[2].right());
            QVERIFY(ink[4].left() > ink[3].right());
        }

        // Exact captured AR names, encoded only after authoritative MdC mapping.
        // This tests reader shaping; it does not decode MdC or certify all enclosures.
        const QString tut = QString::fromUtf8("𓇋𓏠𓐰𓈖𓏏𓅱𓐴𓏏𓋹");
        const QString akhenaten = QString::fromUtf8("𓍹𓐼𓇋𓏏𓐰𓈖𓐰𓇳𓅜𓐍𓐰𓈖𓐽𓍺");
        const QString before = QString::fromUtf8("قبل ");
        const QString after = QString::fromUtf8(" بعد ");
        const QString caption = QString::fromUtf8("الرابط");
        const auto inkFor = [](const QString &text, const QFont &font) {
            QTextLayout layout(text, font);
            layout.beginLayout();
            QTextLine line = layout.createLine();
            if (line.isValid()) line.setLineWidth(1000);
            layout.endLayout();
            QList<QRectF> ink;
            for (const QGlyphRun &run : layout.glyphRuns()) {
                const auto indexes = run.glyphIndexes();
                const auto positions = run.positions();
                for (qsizetype i = 0; i < indexes.size() && i < positions.size(); ++i) {
                    const QRectF bounds = run.rawFont().pathForGlyph(indexes[i]).boundingRect();
                    if (!bounds.isEmpty()) ink.append(bounds.translated(positions[i]));
                }
            }
            return ink;
        };
        window.resize(780, 480);
        window.show();
        QCoreApplication::processEvents();
        for (const QString &encoded : {tut, akhenaten}) {
            const QJsonArray captured{
                QJsonObject{{QStringLiteral("text"), before}, {QStringLiteral("language"), QStringLiteral("ar")},
                            {QStringLiteral("direction"), QStringLiteral("rtl")}},
                QJsonObject{{QStringLiteral("text"), encoded}, {QStringLiteral("classes"), QStringLiteral("Egyp")},
                            {QStringLiteral("language"), QStringLiteral("egy")}, {QStringLiteral("direction"), QStringLiteral("ltr")}},
                QJsonObject{{QStringLiteral("text"), after}, {QStringLiteral("language"), QStringLiteral("ar")},
                            {QStringLiteral("direction"), QStringLiteral("rtl")}},
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), caption},
                            {QStringLiteral("target"), QStringLiteral("egy-following")}, {QStringLiteral("direction"), QStringLiteral("rtl")}}
            };
            window.reading_->setHtml(window.spansHtml(captured));
            QTextDocument *document = window.reading_->document();
            document->setTextWidth(window.reading_->viewport()->width());
            const QSizeF size = document->documentLayout()->documentSize();
            QCoreApplication::processEvents();
            // Same existing Qt screenshot path, resolved inside the owned test cwd.
            // Retain actual pixels before the new shaping assertions can fail.
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            const QString screenshot = encoded == tut
                ? QStringLiteral(".tmp/ui-screenshots/desktop-egyptian-tut.png")
                : QStringLiteral(".tmp/ui-screenshots/desktop-egyptian-akhenaten.png");
            QVERIFY(window.grab().save(screenshot));
            QVERIFY(qIsFinite(size.width()) && qIsFinite(size.height()));
            QVERIFY(size.width() > 0 && size.height() > 0);
            const QTextCursor signs = document->find(encoded);
            QVERIFY(!signs.isNull());
            QCOMPARE(signs.selectedText(), encoded);
            const QFont font = signs.charFormat().font();
            QVERIFY(font.families().contains(QStringLiteral("NewGardinerOmni")));
            QVERIFY(!document->find(before.trimmed()).isNull());
            QVERIFY(!document->find(after.trimmed()).isNull());
            QVERIFY(!document->find(after.trimmed()).charFormat().font().families()
                         .contains(QStringLiteral("NewGardinerOmni")));
            QCOMPARE(document->find(caption).charFormat().anchorHref(), QStringLiteral("dict:egy-following"));
            const QTextBlock block = signs.block();
            qsizetype painted = 0;
            for (const QGlyphRun &run : block.layout()->glyphRuns(signs.selectionStart() - block.position(), encoded.size())) {
                QCOMPARE(run.rawFont().familyName(), QStringLiteral("NewGardinerOmni"));
                const auto indexes = run.glyphIndexes();
                const auto positions = run.positions();
                QCOMPARE(indexes.size(), positions.size());
                for (qsizetype i = 0; i < indexes.size(); ++i) {
                    QVERIFY(indexes[i] != 0);
                    const QRectF bounds = run.rawFont().pathForGlyph(indexes[i]).boundingRect().translated(positions[i]);
                    QVERIFY(qIsFinite(bounds.left()) && qIsFinite(bounds.top()) &&
                            qIsFinite(bounds.width()) && qIsFinite(bounds.height()));
                    if (!bounds.isEmpty()) ++painted;
                }
            }
            QVERIFY(painted > 0);
            if (encoded == tut) {
                QString withoutInsertion = encoded;
                withoutInsertion.remove(QString::fromUtf8("𓐴"));
                // Ignore invisible control glyphs: require an actual ink-layout change.
                QVERIFY(inkFor(encoded, font) != inkFor(withoutInsertion, font));
            }
        }
    }

    void genericAdvisoriesPreserveTextGeometryAndKeyboardDetails() {
        QSettings settings;
        const bool hadImagePermission = settings.contains(QStringLiteral("media/allowImages"));
        const QVariant imagePermission = settings.value(QStringLiteral("media/allowImages"));
        const auto restorePermission = qScopeGuard([&] {
            if (hadImagePermission) settings.setValue(QStringLiteral("media/allowImages"), imagePermission);
            else settings.remove(QStringLiteral("media/allowImages"));
        });
        settings.setValue(QStringLiteral("media/allowImages"), false);
        MainWindow window(fixture_, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 120000);
        const QString expansion = QStringLiteral("Separate abbreviation expansion");
        const QString reserved = SemanticHtml::scalePrefix + QStringLiteral("literal <b>literal</b> & \"quoted\"\nnext line");
        const auto text = [](const QString &label, const QJsonValue &advice) {
            return QJsonObject{{"kind", "text"}, {"text", label}, {"tooltip", advice}};
        };
        // Advisory-only markers must preserve every existing font, paint, action
        // and layout property, including zero scale and normal-body scale one.
        for (double scale : {0.0, 1.0, 1.25}) {
            for (const QString &basis : {QStringLiteral("context"), QStringLiteral("normal_body")}) {
                QJsonObject original{{"kind", "link"}, {"text", "Advice"}, {"target", "cat"}, {"trail", "!"},
                    {"explanation", expansion}, {"font_scale", scale}, {"font_scale_basis", basis},
                    {"small", true}, {"italic", true}, {"background", "#ccffff"}};
                QJsonObject nullAdvice = original; nullAdvice.insert("tooltip", QJsonValue::Null);
                QCOMPARE(window.spansHtml(QJsonArray{nullAdvice}), window.spansHtml(QJsonArray{original}));
                for (const QString &advice : {QString(), reserved, expansion}) {
                    QJsonObject annotated = original; annotated.insert("tooltip", advice);
                    for (int surface = 0; surface != 3; ++surface) {
                        const auto html = [&](const QJsonObject &span) {
                            const QJsonArray spans{span};
                            if (surface == 1) return window.blockHtml(QJsonObject{{"kind", "heading"}, {"level", 3}, {"spans", spans}});
                            if (surface == 2) return window.tableHtml(QJsonObject{{"caption", spans}, {"rows", QJsonArray{
                                QJsonObject{{"cells", QJsonArray{QJsonObject{{"spans", spans}}}}}}}}, 0);
                            return window.spansHtml(spans);
                        };
                        QTextDocument baseline, actual;
                        QFont font; font.setPointSizeF(12);
                        for (auto *document : {&baseline, &actual}) { document->setDefaultFont(font); document->setTextWidth(320); }
                        SemanticHtml::setHtml(&baseline, html(original));
                        SemanticHtml::setHtml(&actual, html(annotated));
                        QCOMPARE(actual.toPlainText(), baseline.toPlainText());
                        QCOMPARE(actual.characterCount(), baseline.characterCount());
                        QCOMPARE(actual.documentLayout()->documentSize(), baseline.documentLayout()->documentSize());
                        for (int offset = 0; offset < actual.characterCount() - 1; ++offset) {
                            QTextCursor expected(&baseline), observed(&actual);
                            expected.setPosition(offset); expected.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
                            observed.setPosition(offset); observed.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
                            auto before = expected.charFormat(), after = observed.charFormat();
                            if (after.hasProperty(SemanticHtml::spanAdvisoryProperty)) {
                                QCOMPARE(after.toolTip(), advice);
                                QCOMPARE(SemanticHtml::spanExplanation(after), expansion);
                            }
                            for (int property : {int(QTextFormat::TextToolTip), SemanticHtml::spanAdvisoryProperty, SemanticHtml::spanExpansionProperty}) {
                                before.clearProperty(property); after.clearProperty(property);
                            }
                            QCOMPARE(after, before);
                        }
                        const auto link = actual.find(QStringLiteral("Advice"));
                        QVERIFY(!link.isNull());
                        QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("dict:cat"));
                        QCOMPARE(link.charFormat().toolTip(), advice);
                        QCOMPARE(link.selection().toPlainText(), QStringLiteral("Advice"));
                    }
                }
            }
        }
        QJsonObject invalid = text(QStringLiteral("bad"), true);
        QVERIFY_EXCEPTION_THROWN(window.spansHtml(QJsonArray{invalid}), DictApiError);

        QJsonObject linked = text(QStringLiteral("Linked advice"), reserved);
        linked.insert("kind", "link"); linked.insert("target", "cat");
        QJsonObject equal = text(QStringLiteral("same"), expansion); equal.insert("explanation", expansion);
        QJsonObject suppressed = text(QStringLiteral("suppressed"), QString()); suppressed.insert("explanation", expansion);
        QJsonObject inherited = text(QStringLiteral("legacy"), QJsonValue::Null); inherited.insert("explanation", expansion);
        QJsonObject legacyEdge = text(QStringLiteral("legacy-edge"), QJsonValue::Null); legacyEdge.insert("explanation", expansion);
        QJsonObject image{{"kind", "link"}, {"text", ""}, {"target", "File:Tooltip-fixture.svg"},
            {"tooltip", "Image span advice"}, {"explanation", "Image expansion"},
            {"image", QJsonObject{{"file", "Tooltip-fixture.svg"}, {"width_px", 20}, {"height_px", 20}}}};
        QJsonObject emptyImage = image, ownImage = image;
        auto imageData = image.value("image").toObject(); imageData.insert("tooltip", ""); emptyImage.insert("image", imageData);
        imageData.insert("tooltip", "Own image advice"); ownImage.insert("image", imageData);
        const QString imageAdvice = QStringLiteral("<b>literal image</b> & \"quoted\"\nimage line");
        QJsonObject imageOnly = image, emptyImageOnly = image, legacyImageOnly = image;
        for (QJsonObject *value : {&imageOnly, &emptyImageOnly, &legacyImageOnly}) value->insert("tooltip", QJsonValue::Null);
        imageData = image.value("image").toObject(); imageData.insert("tooltip", imageAdvice); imageOnly.insert("image", imageData);
        imageData.insert("tooltip", ""); emptyImageOnly.insert("image", imageData);
        QJsonObject lineBreak = text(QString(), QStringLiteral("Break advice")); lineBreak.insert("kind", "line_break");
        QJsonObject zeroAdvice = text(QStringLiteral("Zero advice label"), QStringLiteral("Zero range advice"));
        zeroAdvice.insert("font_scale", 0);
        const QJsonArray body{linked, text(" ", QJsonValue::Null), equal, text(" ", QJsonValue::Null), suppressed,
            text(" ", QJsonValue::Null), inherited, text(" ", QJsonValue::Null),
            text("owned/", "Boundary advice"), legacyEdge, lineBreak, text("", "Empty range advice"),
            text("  ", "Whitespace advice"), image, emptyImage, ownImage, imageOnly, emptyImageOnly, legacyImageOnly, zeroAdvice};
        const QJsonObject heading{{"kind", "heading"}, {"level", 3}, {"spans", QJsonArray{text("Advised heading", "Heading advice")}}};
        const QJsonObject cellParagraph{{"kind", "paragraph"}, {"spans", QJsonArray{text("Cell", "Cell advice")}}};
        const QJsonObject cell{{"blocks", QJsonArray{cellParagraph}}};
        const QJsonObject row{{"cells", QJsonArray{cell}}};
        const QJsonObject table{{"caption", QJsonArray{text("Caption", "Caption advice")}}, {"rows", QJsonArray{row}}};
        const QJsonObject paragraph{{"kind", "paragraph"}, {"spans", body}};
        const QJsonObject tableBlock{{"kind", "table"}, {"table", table}};
        const QJsonObject section{{"title", "Advised heading"}, {"level", 3}, {"blocks", QJsonArray{heading, paragraph, tableBlock}}};
        const QJsonObject referenceParagraph{{"kind", "paragraph"}, {"spans", QJsonArray{text("Reference", "Reference advice")}}};
        const QJsonObject reference{{"kind", "note"}, {"number", 1}, {"group_number", 1}, {"spans", QJsonArray{}}, {"blocks", QJsonArray{referenceParagraph}}};
        const QJsonObject entry{{"title", "Tooltip consumer control"}, {"kind", "language"}, {"language", window.api_->language()},
            {"display_title", QJsonArray{text("Tooltip consumer control", "Title advice")}},
            {"preamble_spans", QJsonArray{text("Preamble", "Preamble advice")}}, {"sections", QJsonArray{section}},
            {"references", QJsonArray{reference}}};
        const QByteArray response = QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson();
        window.show(); QTRY_VERIFY(window.isVisible());
        window.resize(640, 600); window.activateWindow();
        window.renderResponse(response, false);
        QWidget *readingSwitch = window.compactToolbar_->widgetForAction(window.readingPaneAction_);
        QVERIFY(readingSwitch);
        qInfo() << "Advisory surface before readiness" << window.size() << window.isVisible()
                << window.compactNavigation_ << window.compactToolbar_->isVisible()
                << readingSwitch->isVisible() << readingSwitch->isEnabled();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        const QString frameStem = QStringLiteral(".tmp/ui-screenshots/generic-advisory-%1").arg(QCoreApplication::applicationPid());
        QVERIFY(window.grab().save(frameStem + QStringLiteral("-surface.png")));
        QTRY_COMPARE(window.size(), QSize(640, 600));
        QTRY_VERIFY(window.compactNavigation_);
        QTRY_VERIFY(readingSwitch->isVisible() && readingSwitch->isEnabled());
        QCoreApplication::processEvents();
        QVERIFY(window.grab().save(frameStem + QStringLiteral("-settled-surface.png")));
        QTest::mouseClick(readingSwitch, Qt::LeftButton);
        QTRY_VERIFY(window.reading_->isVisible());
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        const QString visible = window.reading_->toPlainText();
        QCOMPARE(visible.count(QStringLiteral("Advised heading")), 1);
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(QJsonDocument::fromJson(window.currentJson_).object(), QJsonObject({{"entries", QJsonArray{entry}}}));
        QCOMPARE(window.title_->accessibleName(), QStringLiteral("Tooltip consumer control"));
        const auto advisories = window.readingAdvisories();
        QVERIFY(advisories.contains(qMakePair(QString(), QStringLiteral("Empty range advice"))));
        QVERIFY(advisories.contains(qMakePair(QString(), QStringLiteral("Break advice"))));
        QVERIFY(advisories.contains(qMakePair(QStringLiteral("  "), QStringLiteral("Whitespace advice"))));
        QVERIFY(advisories.contains(qMakePair(QString(), QStringLiteral("Image span advice"))));
        QVERIFY(advisories.contains(qMakePair(QString(), QStringLiteral("Own image advice"))));
        QVERIFY(advisories.contains(qMakePair(QString(), imageAdvice)));
        QVERIFY(advisories.contains(qMakePair(QStringLiteral("Zero advice label"), QStringLiteral("Zero range advice"))));
        for (const QString &label : {QStringLiteral("Title"), QStringLiteral("Preamble"), QStringLiteral("Heading"),
             QStringLiteral("Caption"), QStringLiteral("Cell"), QStringLiteral("Reference")}) {
            bool found = false;
            for (const auto &row : advisories) found = found || row.second == label + QStringLiteral(" advice");
            QVERIFY(found);
        }
        const auto explanations = window.readingExplanations();
        QVERIFY(explanations.contains(qMakePair(QStringLiteral("same"), expansion)));
        QVERIFY(explanations.contains(qMakePair(QStringLiteral("suppressed"), expansion)));
        QVERIFY(explanations.contains(qMakePair(QStringLiteral("legacy"), expansion)));
        QVERIFY(!explanations.contains(qMakePair(QStringLiteral("Linked advice"), reserved)));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("suppressed")).charFormat().toolTip(), QString());
        QCOMPARE(window.reading_->document()->find(QStringLiteral("legacy")).charFormat().toolTip(), expansion);
        const auto hoverAt = [&](QTextBrowser *browser, const QTextCursor &found, const QString &raw,
                                 bool browserEvent = false, bool adjacentLegacy = false) {
            QVERIFY(!found.isNull());
            QTextCursor start = found; start.setPosition(found.selectionStart());
            QTextCursor end = start; end.movePosition(QTextCursor::NextCharacter);
            const QRect first = browser->cursorRect(start), last = browser->cursorRect(end);
            const int glyphWidth = last.left() - first.left();
            if (adjacentLegacy) QVERIFY(glyphWidth > 1);
            const QPoint local(adjacentLegacy ? first.left() + qMax(1, glyphWidth / 4)
                                              : (first.left() + last.left()) / 2, first.center().y());
            QVERIFY(browser->viewport()->rect().contains(local));
            const auto *horizontal = browser->horizontalScrollBar();
            const int horizontalOffset = browser->isRightToLeft() ? horizontal->maximum() - horizontal->value() : horizontal->value();
            const QPoint documentPoint = local + QPoint(horizontalOffset, browser->verticalScrollBar()->value());
            QCOMPARE(browser->document()->documentLayout()->hitTest(documentPoint, Qt::ExactHit), found.selectionStart());
            if (adjacentLegacy) {
                QVERIFY(!found.charFormat().hasProperty(SemanticHtml::spanAdvisoryProperty));
                QVERIFY(browser->cursorForPosition(local).charFormat().hasProperty(SemanticHtml::spanAdvisoryProperty));
            }
            const QPoint receiverPoint = browserEvent ? browser->viewport()->mapTo(browser, local) : local;
            QHelpEvent help(QEvent::ToolTip, receiverPoint, browser->viewport()->mapToGlobal(local));
            QApplication::sendEvent(browserEvent ? browser : browser->viewport(), &help);
            if (raw.isEmpty()) { QTRY_VERIFY(!QToolTip::isVisible()); return; }
            QTRY_VERIFY(QToolTip::isVisible());
            QTextDocument display; display.setHtml(QToolTip::text());
            QCOMPARE(display.toPlainText(), raw);
            QCOMPARE(found.charFormat().toolTip(), raw);
            QVERIFY(!display.toPlainText().contains(QStringLiteral("<span style=")));
        };
        const auto hover = [&](QTextBrowser *browser, const QString &label, const QString &raw) {
            hoverAt(browser, browser->document()->find(label), raw);
        };
        QVERIFY(window.grab().save(frameStem + QStringLiteral("-reading.png")));
        hover(window.reading_, QStringLiteral("Linked advice"), reserved);
        hoverAt(window.reading_, window.reading_->document()->find(QStringLiteral("Linked advice")), reserved, true);
        // A nonempty legacy tooltip must replace owned advice normally.
        hover(window.reading_, QStringLiteral("egacy"), expansion);
        hoverAt(window.reading_, window.reading_->document()->find(QStringLiteral("legacy-edge")), expansion, false, true);
        hover(window.title_, QStringLiteral("Tooltip consumer control"), QStringLiteral("Title advice"));
        const QPoint blank(window.title_->viewport()->rect().right() - 2, window.title_->viewport()->rect().center().y());
        const int blankOffset = window.title_->document()->documentLayout()->hitTest(blank, Qt::ExactHit);
        QVERIFY(blankOffset < 0);
        const QTextCharFormat blankNearest = window.title_->cursorForPosition(blank).charFormat();
        qInfo() << "Advisory blank hit" << blankOffset << window.title_->document()->characterCount()
                << blankNearest.toolTip() << blankNearest.hasProperty(SemanticHtml::spanAdvisoryProperty)
                << QToolTip::text();
        QHelpEvent blankHelp(QEvent::ToolTip, blank, window.title_->viewport()->mapToGlobal(blank));
        QApplication::sendEvent(window.title_->viewport(), &blankHelp);
        qInfo() << "Advisory blank delivered" << blankHelp.isAccepted() << QToolTip::isVisible() << QToolTip::text();
        QVERIFY(!blankHelp.isAccepted());
        if (QToolTip::isVisible())
            QCOMPARE(QToolTip::text(), QStringLiteral("<span style='white-space:pre-wrap'>Title advice</span>"));
        QTRY_VERIFY(!QToolTip::isVisible());
        // A blank point nearest legacy text must not regain its tooltip when
        // the ignored viewport event propagates after owned tracking is cleared.
        hover(window.reading_, QStringLiteral("Linked advice"), reserved);
        const QTextCursor legacyEnd = window.reading_->document()->find(QStringLiteral("legacy"));
        const QPoint legacyBlank(window.reading_->viewport()->rect().right() - 2,
                                 window.reading_->cursorRect(legacyEnd).center().y());
        const auto *legacyHorizontal = window.reading_->horizontalScrollBar();
        const int legacyHorizontalOffset = window.reading_->isRightToLeft()
            ? legacyHorizontal->maximum() - legacyHorizontal->value() : legacyHorizontal->value();
        const QPoint legacyDocumentPoint = legacyBlank + QPoint(legacyHorizontalOffset,
                                                                window.reading_->verticalScrollBar()->value());
        QVERIFY(window.reading_->document()->documentLayout()->hitTest(legacyDocumentPoint, Qt::ExactHit) < 0);
        const QTextCharFormat nearestLegacy = window.reading_->cursorForPosition(legacyBlank).charFormat();
        QVERIFY(!nearestLegacy.hasProperty(SemanticHtml::spanAdvisoryProperty));
        QCOMPARE(nearestLegacy.toolTip(), expansion);
        QHelpEvent legacyBlankHelp(QEvent::ToolTip, legacyBlank, window.reading_->viewport()->mapToGlobal(legacyBlank));
        QApplication::sendEvent(window.reading_->viewport(), &legacyBlankHelp);
        QVERIFY(!legacyBlankHelp.isAccepted());
        QTRY_VERIFY(!QToolTip::isVisible());

        // Scrollbar help is outside the text viewport. Its own accepted advice
        // still works, while browser-level misses cannot pick offscreen text.
        QScrollBar *scrollbar = window.reading_->verticalScrollBar();
        QVERIFY(scrollbar->isVisible());
        const QPoint barPoint = scrollbar->rect().center();
        const QPoint browserBarPoint = scrollbar->mapTo(window.reading_, barPoint);
        QVERIFY(!window.reading_->viewport()->rect().contains(window.reading_->viewport()->mapFrom(window.reading_, browserBarPoint)));
        hover(window.reading_, QStringLiteral("Linked advice"), reserved);
        QHelpEvent outsideHelp(QEvent::ToolTip, browserBarPoint, scrollbar->mapToGlobal(barPoint));
        QApplication::sendEvent(window.reading_, &outsideHelp);
        QVERIFY(!outsideHelp.isAccepted());
        QTRY_VERIFY(!QToolTip::isVisible());
        const QString oldBarTip = scrollbar->toolTip();
        scrollbar->setToolTip(QStringLiteral("Scrollbar help control"));
        QHelpEvent barHelp(QEvent::ToolTip, barPoint, scrollbar->mapToGlobal(barPoint));
        QApplication::sendEvent(scrollbar, &barHelp);
        scrollbar->setToolTip(oldBarTip);
        QVERIFY(barHelp.isAccepted());
        QTRY_VERIFY(QToolTip::isVisible());
        QCOMPARE(QToolTip::text(), QStringLiteral("Scrollbar help control"));
        hover(window.reading_, QStringLiteral("Cell"), QStringLiteral("Cell advice"));
        hover(window.reading_, QStringLiteral("suppressed"), QString());
        const QString uncataloguedMessage = QStringLiteral("This image is not in the dictionary's media catalogue.");
        const auto imagesUncatalogued = [&] {
            int count = 0;
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const QTextCharFormat format = it.fragment().charFormat();
                    if (!format.isImageFormat()) continue;
                    ++count;
                    if (!format.hasProperty(SemanticHtml::inlineImageStateProperty)
                        || format.intProperty(SemanticHtml::inlineImageStateProperty) != int(MediaPanel::InlineImageState::Error)
                        || format.stringProperty(SemanticHtml::inlineImageStatusProperty) != uncataloguedMessage) return false;
                }
            return count == 6;
        };
        const auto logImageState = [&](const char *phase) {
            int count = 0;
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const QTextFragment fragment = it.fragment();
                    const QTextCharFormat format = fragment.charFormat();
                    if (!format.isImageFormat()) continue;
                    qInfo() << "Advisory image readiness" << phase << count++ << fragment.position() << format.properties();
                }
            qInfo() << "Advisory image readiness count" << phase << count;
        };
        // This fixture has no media catalogue. Its queued resource application
        // reports the exact catalogue error without registering a network request.
        logImageState("before");
        const bool imagesReady = QTest::qWaitFor(imagesUncatalogued, 5000);
        logImageState(imagesReady ? "ready" : "failed");
        QVERIFY(imagesReady);
        QList<QTextImageFormat> formats;
        QList<int> imagePositions;
        for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
            for (auto it = block.begin(); !it.atEnd(); ++it)
                if (it.fragment().charFormat().isImageFormat()) {
                    formats.append(it.fragment().charFormat().toImageFormat());
                    imagePositions.append(it.fragment().position());
                }
        QCOMPARE(formats.size(), 6);
        QCOMPARE(formats[0].toolTip(), QStringLiteral("Image span advice"));
        QCOMPARE(formats[1].toolTip(), QString());
        QCOMPARE(formats[2].toolTip(), QStringLiteral("Own image advice"));
        QCOMPARE(formats[3].toolTip(), imageAdvice);
        QCOMPARE(formats[4].toolTip(), QString());
        QCOMPARE(formats[5].toolTip(), QStringLiteral("Image expansion"));
        for (int index : {3, 4, 5}) {
            QVERIFY(!formats[index].hasProperty(SemanticHtml::spanAdvisoryProperty));
            QCOMPARE(formats[index].hasProperty(QTextFormat::ImageTitle), index != 5);
            QTextCursor occurrence(window.reading_->document()); occurrence.setPosition(imagePositions[index]);
            occurrence.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            const QTextCharFormat cursorBefore = occurrence.charFormat();
            QTextCharFormat expectedCursor(formats[index]);
            expectedCursor.clearProperty(QTextFormat::ObjectIndex); // Qt's cursor API projection only.
            qInfo() << "Advisory image format before" << index << "cursor" << cursorBefore.properties()
                    << "fragment" << formats[index].properties();
            QCOMPARE(cursorBefore, expectedCursor);
            hoverAt(window.reading_, occurrence, formats[index].toolTip());
            const QTextCharFormat cursorAfter = occurrence.charFormat();
            if (cursorAfter != cursorBefore)
                qInfo() << "Advisory image cursor changed" << index << cursorBefore.properties() << cursorAfter.properties();
            QCOMPARE(cursorAfter, cursorBefore);
            QTextCharFormat fragmentAfter;
            bool foundFragment = false;
            const QTextBlock imageBlock = window.reading_->document()->findBlock(imagePositions[index]);
            for (auto it = imageBlock.begin(); !it.atEnd(); ++it) {
                const QTextFragment fragment = it.fragment();
                if (fragment.position() <= imagePositions[index]
                    && imagePositions[index] < fragment.position() + fragment.length()) {
                    fragmentAfter = fragment.charFormat(); foundFragment = true; break;
                }
            }
            QVERIFY(foundFragment);
            if (fragmentAfter != formats[index])
                qInfo() << "Advisory image fragment changed" << index << formats[index].properties() << fragmentAfter.properties();
            QCOMPARE(fragmentAfter, QTextCharFormat(formats[index]));
            QVERIFY(imagesUncatalogued());
        }
        QToolTip::hideText();
        for (const auto &format : formats) {
            QCOMPARE(format.stringProperty(SemanticHtml::inlineImageExplanationProperty), QStringLiteral("Image expansion"));
            QCOMPARE(format.anchorHref(), QStringLiteral("media-source:File%3ATooltip-fixture.svg"));
            QCOMPARE(format.width(), 20.0); QCOMPARE(format.height(), 20.0);
        }
        QTextCursor selected = window.reading_->document()->find(QStringLiteral("Linked advice"));
        QVERIFY(!selected.isNull()); window.reading_->setTextCursor(selected);
        const auto selectedText = selected.selection().toPlainText();
        const QString href = selected.charFormat().anchorHref();
        QVERIFY(!href.isEmpty());
        bool inspected = false, expired = false;
        QTimer deadline; deadline.setSingleShot(true);
        connect(&deadline, &QTimer::timeout, &window, [&] {
            expired = true;
            for (QDialog *dialog : window.findChildren<QDialog *>()) dialog->reject();
            for (QMenu *menu : window.findChildren<QMenu *>()) menu->close();
        });
        deadline.start(3000);
        QTimer::singleShot(0, &window, [&] {
            auto *menu = window.findChild<QMenu *>(QStringLiteral("readerContextMenu")); QVERIFY(menu);
            auto *action = menu->findChild<QAction *>(QStringLiteral("entryAbbreviations")); QVERIFY(action);
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = window.findChild<QDialog *>(QStringLiteral("abbreviationsDialog")); QVERIFY(dialog);
                auto *details = dialog->findChild<QTextBrowser *>(QStringLiteral("abbreviationExplanations")); QVERIFY(details);
                const QString contents = details->toPlainText();
                QVERIFY(contents.contains(QStringLiteral("Abbreviation expansions")));
                QVERIFY(contents.contains(QStringLiteral("Advisory information")));
                QVERIFY(contents.contains(reserved));
                QVERIFY(contents.contains(imageAdvice));
                QVERIFY(contents.contains(QStringLiteral("Empty range advice")));
                QVERIFY(contents.contains(QStringLiteral("Break advice")));
                QVERIFY(contents.contains(QStringLiteral("Zero range advice")));
                QCOMPARE(details->accessibleName(), QStringLiteral("Text details"));
                QVERIFY(details->textInteractionFlags().testFlag(Qt::TextSelectableByKeyboard));
                QVERIFY(dialog->grab().save(frameStem + QStringLiteral("-details.png")));
                inspected = true; dialog->reject();
            });
            menu->setActiveAction(action); QTest::keyClick(menu, Qt::Key_Return);
        });
        QTest::keyClick(window.reading_, Qt::Key_F10, Qt::ShiftModifier);
        deadline.stop(); QVERIFY(!expired); QVERIFY(inspected);
        QTRY_VERIFY(window.reading_->hasFocus());
        QCOMPARE(window.reading_->textCursor().selection().toPlainText(), selectedText);
        QCOMPARE(window.reading_->textCursor().charFormat().anchorHref(), href);
        QCOMPARE(window.reading_->toPlainText(), visible);
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(QJsonDocument::fromJson(window.currentJson_).object(), QJsonObject({{"entries", QJsonArray{entry}}}));
        window.resize(900, 600); window.resize(640, 600); window.refreshReading();
        QCOMPARE(window.reading_->toPlainText(), visible);
        QCOMPARE(window.readingAdvisories(), advisories);
        QCOMPARE(window.readingExplanations(), explanations);
        QCOMPARE(window.currentEntry_, entry);
        // Text details describes the compiled entry, including folded ranges;
        // folding does not erase metadata or insert replacement body text.
        window.collapsedSections_.insert(0); window.refreshReading();
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Linked advice")));
        QCOMPARE(window.readingAdvisories(), advisories);
        QCOMPARE(window.currentEntry_, entry);
        window.collapsedSections_.remove(0); window.refreshReading();
        QCOMPARE(window.reading_->toPlainText(), visible);
        QCOMPARE(window.readingAdvisories(), advisories);
        QCOMPARE(window.currentEntry_, entry);
        // Present-empty heading advice still selects the single rich companion.
        const QJsonObject emptyHeading{{"kind", "heading"}, {"level", 3},
            {"spans", QJsonArray{text("Advised heading", QString())}}};
        const QJsonObject genericParagraph{{"kind", "paragraph"}, {"spans", QJsonArray{linked}}};
        const QJsonObject genericSection{{"title", "Advised heading"}, {"level", 3}, {"blocks", QJsonArray{emptyHeading, genericParagraph}}};
        const QJsonObject genericEntry{{"title", "Generic advice only"}, {"kind", "language"}, {"language", window.api_->language()},
            {"sections", QJsonArray{genericSection}}};
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{genericEntry}}}).toJson(), false);
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Advised heading")), 1);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Advised heading")).charFormat().toolTip(), QString());
        QVERIFY(window.readingExplanations().isEmpty());
        QCOMPARE(window.readingAdvisories().size(), 1);
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        inspected = false; expired = false; deadline.start(3000);
        QTimer::singleShot(0, &window, [&] {
            auto *menu = window.findChild<QMenu *>(QStringLiteral("readerContextMenu")); QVERIFY(menu);
            auto *action = menu->findChild<QAction *>(QStringLiteral("entryAbbreviations")); QVERIFY(action);
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = window.findChild<QDialog *>(QStringLiteral("abbreviationsDialog")); QVERIFY(dialog);
                auto *details = dialog->findChild<QTextBrowser *>(QStringLiteral("abbreviationExplanations")); QVERIFY(details);
                QVERIFY(details->toPlainText().contains(QStringLiteral("Advisory information")));
                QVERIFY(details->toPlainText().contains(reserved));
                QVERIFY(!details->toPlainText().contains(QStringLiteral("Abbreviation expansions")));
                inspected = true; dialog->reject();
            });
            menu->setActiveAction(action); QTest::keyClick(menu, Qt::Key_Return);
        });
        QTest::keyClick(window.reading_, Qt::Key_F10, Qt::ShiftModifier);
        deadline.stop(); QVERIFY(!expired); QVERIFY(inspected);
        QTRY_VERIFY(window.reading_->hasFocus());
        QCOMPARE(window.currentEntry_, genericEntry);
        // Qt reverses the horizontal content offset for RTL widgets. Use a real
        // scrolled text range, not an unscrolled direction flag alone.
        window.reading_->setLayoutDirection(Qt::RightToLeft);
        window.reading_->setLineWrapMode(QTextEdit::NoWrap);
        window.reading_->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
        QJsonObject rtlEntry = genericEntry;
        const QJsonArray longSpans{text(QStringLiteral("Leading words ").repeated(60), QJsonValue::Null), linked,
            text(QStringLiteral(" trailing words").repeated(100), QJsonValue::Null)};
        const QJsonObject longParagraph{{"kind", "paragraph"}, {"spans", longSpans}};
        rtlEntry.insert("sections", QJsonArray{QJsonObject{{"title", "RTL scroll control"}, {"level", 3}, {"blocks", QJsonArray{longParagraph}}}});
        window.renderResponse(QJsonDocument(QJsonObject{{"entries", QJsonArray{rtlEntry}}}).toJson(), false);
        const QTextCursor rtlLink = window.reading_->document()->find(QStringLiteral("Linked advice")); QVERIFY(!rtlLink.isNull());
        window.reading_->setTextCursor(rtlLink); window.reading_->ensureCursorVisible();
        auto *horizontal = window.reading_->horizontalScrollBar();
        QTRY_VERIFY(horizontal->isVisible() && horizontal->maximum() > 0);
        QVERIFY(horizontal->value() > 0);
        QVERIFY(horizontal->maximum() - horizontal->value() != horizontal->value());
        hover(window.reading_, QStringLiteral("Linked advice"), reserved);
        QCOMPARE(window.currentEntry_, rtlEntry);
        QToolTip::hideText();
    }

    void abbreviationExplanationsPreserveCopyLinksAndKeyboardAccess() {
        // Required ordinary native test-bundle output; no hand-built interoperability fallback.
        QString interopRoot = qEnvironmentVariable("DICT_ABBREVIATION_INTEROP_ROOT");
        if (interopRoot.isEmpty()) interopRoot = QDir(fixture_).filePath(QStringLiteral("abbreviation-interop"));
        const QString source = QDir(interopRoot).filePath(QStringLiteral(
            "languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
        QVERIFY2(QFileInfo::exists(source), qPrintable(source));
        QTemporaryDir imported(QStringLiteral(".tmp/ui-native-abbreviations-XXXXXX"));
        QVERIFY(imported.isValid());
        const QString root = imported.path() + QStringLiteral("/library");
        std::atomic_bool cancelled = false;
        auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled,
            [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        {
            DictApi actual(root);
            actual.select(QStringLiteral("English"), QStringLiteral("language"));
            const std::array<QPair<QString, QString>, 2> samples{{
                {QStringLiteral("Acupuncture abbreviation sample"), QStringLiteral("annotated.export.json")},
                {QStringLiteral("Legacy format abbreviation control"), QStringLiteral("legacy.export.json")}
            }};
            for (const auto &sample : samples) {
                QFile exported(QDir(interopRoot).filePath(sample.second));
                QVERIFY2(exported.open(QIODevice::ReadOnly), qPrintable(exported.fileName()));
                QJsonParseError exportError;
                const QJsonDocument expected = QJsonDocument::fromJson(exported.readAll(), &exportError);
                QCOMPARE(exportError.error, QJsonParseError::NoError);
                QVERIFY(expected.isObject());
                const QJsonArray expectedEntries = expected.object().value(QStringLiteral("entries")).toArray();
                QCOMPARE(expectedEntries.size(), 1);
                QVERIFY(expectedEntries.first().isObject());
                QJsonParseError lookupError;
                const QJsonDocument observed = QJsonDocument::fromJson(actual.lookup(sample.first), &lookupError);
                QCOMPARE(lookupError.error, QJsonParseError::NoError);
                QVERIFY(observed.isObject());
                const QJsonArray actualEntries = observed.object().value(QStringLiteral("entries")).toArray();
                QCOMPARE(actualEntries.size(), 1);
                // Compare the entire typed Entry, not operation-specific export/lookup envelopes.
                QCOMPARE(actualEntries.first(), expectedEntries.first());
                QCOMPARE(actualEntries.first().toObject().value(QStringLiteral("title")).toString(), sample.first);
            }
        }
        MainWindow window(root, QStringLiteral("Acupuncture abbreviation sample"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(780, 480);
        window.show();
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("Acupuncture abbreviation sample"), 30000);
        QTRY_VERIFY_WITH_TIMEOUT(!window.reading_->toPlainText().isEmpty(), 30000);
        const QVector<QPair<QString, QString>> nativeExplanations{
            {QStringLiteral("der."), QStringLiteral("derived terms")},
            {QStringLiteral("?"), QStringLiteral("uncertain")},
            {QStringLiteral("lbor."), QStringLiteral("learned borrowing")},
            {QStringLiteral("f"), QStringLiteral("feminine gender")},
            {QStringLiteral("c"), QStringLiteral("common gender")},
            {QStringLiteral("m"), QStringLiteral("masculine gender")},
            {QStringLiteral("n"), QStringLiteral("neuter gender")}
        };
        QCOMPARE(window.readingExplanations(), nativeExplanations);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("der. ? lbor. f c m n")));
        const QTextCursor derived = window.reading_->document()->find(QStringLiteral("der."));
        const QTextCursor learned = window.reading_->document()->find(QStringLiteral("lbor."));
        QVERIFY(!derived.isNull() && !learned.isNull());
        QCOMPARE(QUrl::fromPercentEncoding(derived.charFormat().anchorHref().mid(5).toUtf8()),
                 QStringLiteral("Appendix:Glossary#derived terms"));
        QCOMPARE(QUrl::fromPercentEncoding(learned.charFormat().anchorHref().mid(5).toUtf8()),
                 QStringLiteral("Appendix:Glossary#learned borrowing"));
        QVERIFY(derived.charFormat().anchorHref().startsWith(QStringLiteral("dict:")));
        QVERIFY(learned.charFormat().anchorHref().startsWith(QStringLiteral("dict:")));
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-native-abbreviations-reader.png")));
        QVERIFY(window.openWord(QStringLiteral("Legacy format abbreviation control")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("Legacy format abbreviation control"), 30000);
        QTRY_VERIFY_WITH_TIMEOUT(window.reading_->toPlainText().contains(QStringLiteral("Plain control.")), 30000);
        QVERIFY(window.readingExplanations().isEmpty());
        const QTextCursor control = window.reading_->document()->find(QStringLiteral("control"));
        QVERIFY(!control.isNull());
        QCOMPARE(control.charFormat().anchorHref(), QStringLiteral("dict:cat"));
        const QString feminine = QStringLiteral("feminine gender");
        const QString styled = QString::fromUtf8("expanded <plain> \"quoted\" العربية");
        const QJsonArray spans{
            QJsonObject{{"kind", "link"}, {"text", "f"}, {"target", "cat"}, {"explanation", feminine}},
            QJsonObject{{"text", " "}},
            QJsonObject{{"text", "ab"}, {"bold", true}, {"explanation", styled}},
            QJsonObject{{"text", "br"}, {"italic", true}, {"explanation", styled}},
            QJsonObject{{"text", " "}},
            QJsonObject{{"text", "f"}, {"explanation", "masculine meaning in another context"}},
            QJsonObject{{"text", " "}},
            QJsonObject{{"text", "?"}, {"explanation", "uncertain"}},
            QJsonObject{{"text", " "}},
            QJsonObject{{"kind", "link"}, {"text", "En-us-girl.ogg"}, {"target", "File:En-us-girl.ogg"},
                {"classes", "wikidict-media wikidict-media-file-456e2d75732d6769726c2e6f6767"},
                {"explanation", "Audio (US)"}}
        };
        window.reading_->setHtml(window.spansHtml(spans));
        QCoreApplication::processEvents();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-abbreviations-reader.png")));
        QCOMPARE(window.reading_->toPlainText(), QStringLiteral("f abbr f ? En-us-girl.ogg"));
        QTextDocument *document = window.reading_->document();
        const QTextCursor first = document->find(QStringLiteral("f"));
        QCOMPARE(first.charFormat().toolTip(), feminine); // Actual Qt HTML import, no fallback parser.
        QCOMPARE(first.charFormat().anchorHref(), QStringLiteral("dict:cat"));
        const auto explanations = window.readingExplanations();
        QCOMPARE(explanations.size(), 5);
        QCOMPARE(explanations.at(0), qMakePair(QStringLiteral("f"), feminine));
        QCOMPARE(explanations.at(1), qMakePair(QStringLiteral("abbr"), styled));
        QCOMPARE(explanations.at(2).first, QStringLiteral("f"));
        QVERIFY(explanations.at(2).second != feminine);
        QCOMPARE(explanations.at(3), qMakePair(QStringLiteral("?"), QStringLiteral("uncertain")));
        QCOMPARE(explanations.at(4), qMakePair(QStringLiteral("En-us-girl.ogg"), QStringLiteral("Audio (US)")));
        const QTextCursor audio = document->find(QStringLiteral("En-us-girl.ogg"));
        QVERIFY(!audio.isNull());
        QCOMPARE(audio.charFormat().toolTip(), QStringLiteral("Audio (US)"));
        QCOMPARE(QUrl::fromPercentEncoding(audio.charFormat().anchorHref().mid(5).toUtf8()),
                 QStringLiteral("File:En-us-girl.ogg"));
        QVERIFY(audio.charFormat().anchorHref().startsWith(QStringLiteral("dict:")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Audio (US)")));
        window.reading_->selectAll();
        QCOMPARE(window.reading_->textCursor().selection().toPlainText(), QStringLiteral("f abbr f ? En-us-girl.ogg"));
        window.activateWindow();
        window.reading_->setFocus();
        auto focusContext = [&] {
            auto describe = [](QWidget *widget) {
                return widget ? QString::fromLatin1(widget->metaObject()->className()) + QStringLiteral("/") + widget->objectName() : QStringLiteral("none");
            };
            return QStringLiteral("active=%1 focus=%2 modal=%3 popup=%4 windowActive=%5 readerVisible=%6 readerEnabled=%7")
                .arg(describe(QApplication::activeWindow()), describe(QApplication::focusWidget()),
                     describe(QApplication::activeModalWidget()), describe(QApplication::activePopupWidget()))
                .arg(window.isActiveWindow()).arg(window.reading_->isVisible()).arg(window.reading_->isEnabled());
        };
        QTRY_VERIFY2(window.reading_->hasFocus(), qPrintable(focusContext()));
        bool inspected = false;
        bool timedOut = false;
        QTimer fallback;
        fallback.setSingleShot(true);
        connect(&fallback, &QTimer::timeout, &window, [&] {
            timedOut = true;
            for (QDialog *dialog : window.findChildren<QDialog *>()) dialog->reject();
            for (QMenu *menu : window.findChildren<QMenu *>()) menu->close();
        });
        fallback.start(2000);
        QTimer::singleShot(0, &window, [&] {
            auto *menu = window.findChild<QMenu *>(QStringLiteral("readerContextMenu"));
            QVERIFY(menu);
            auto *action = menu->findChild<QAction *>(QStringLiteral("entryAbbreviations"));
            QVERIFY(action);
            QCOMPARE(action->text(), QStringLiteral("Text details…"));
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = window.findChild<QDialog *>(QStringLiteral("abbreviationsDialog"));
                QVERIFY(dialog);
                auto *details = dialog->findChild<QTextBrowser *>(QStringLiteral("abbreviationExplanations"));
                QVERIFY(details);
                QCoreApplication::processEvents();
                QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-abbreviations-dialog.png")));
                QCOMPARE(dialog->windowTitle(), QStringLiteral("Text details"));
                QCOMPARE(details->accessibleName(), QStringLiteral("Text details"));
                QVERIFY(details->toPlainText().contains(styled));
                QVERIFY(details->toPlainText().contains(QStringLiteral("f: feminine gender")));
                QVERIFY(details->toPlainText().contains(QStringLiteral("?: uncertain")));
                QVERIFY(details->toPlainText().contains(QStringLiteral("En-us-girl.ogg: Audio (US)")));
                QVERIFY(details->textInteractionFlags().testFlag(Qt::TextSelectableByKeyboard));
                inspected = true;
                dialog->reject();
            });
            menu->setActiveAction(action);
            QTest::keyClick(menu, Qt::Key_Return);
        });
        QTest::keyClick(window.reading_, Qt::Key_F10, Qt::ShiftModifier);
        fallback.stop();
        QVERIFY(!timedOut);
        QVERIFY(inspected);
        QTRY_VERIFY2(window.reading_->hasFocus(), qPrintable(focusContext()));
        QCOMPARE(window.reading_->toPlainText(), QStringLiteral("f abbr f ? En-us-girl.ogg"));
        QCOMPARE(document->find(QStringLiteral("f")).charFormat().anchorHref(), QStringLiteral("dict:cat"));
        QCOMPARE(document->find(QStringLiteral("En-us-girl.ogg")).charFormat().anchorHref(), audio.charFormat().anchorHref());
        window.reading_->setHtml(window.spansHtml(QJsonArray{QJsonObject{{"text", "ordinary"}}}));
        QVERIFY(window.readingExplanations().isEmpty());
        // Explained-only heading companions are rich even without a navigation target.
        const QJsonObject heading{{"kind", "heading"}, {"level", 3},
            {"spans", QJsonArray{QJsonObject{{"text", "Noun"}, {"explanation", "noun meaning"}}}}};
        const QJsonObject section{{"title", "Noun"}, {"level", 3}, {"blocks", QJsonArray{heading}}};
        window.collapsedSections_.clear();
        window.reading_->setHtml(window.entryHtml(QJsonObject{{"sections", QJsonArray{section}}}));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Noun")), 1);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Noun")).charFormat().toolTip(), QStringLiteral("noun meaning"));
        QCOMPARE(window.readingExplanations().size(), 1);
        // A title-only annotation must use the same ordinary reader keyboard route.
        QJsonObject titleResponse = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("Legacy format abbreviation control"))).object();
        QJsonObject titleEntry = titleResponse.value(QStringLiteral("entries")).toArray().first().toObject();
        titleEntry.insert(QStringLiteral("display_title"), QJsonArray{
            QJsonObject{{"text", "f"}, {"explanation", "title feminine gender"}}});
        titleResponse.insert(QStringLiteral("entries"), QJsonArray{titleEntry});
        window.renderResponse(QJsonDocument(titleResponse).toJson(), false);
        QVERIFY(window.title_->isVisible());
        QTextDocument displayedTitle;
        displayedTitle.setHtml(window.title_->toHtml());
        QCOMPARE(displayedTitle.toPlainText(), QStringLiteral("f"));
        const QVector<QPair<QString, QString>> titleOnly{{QStringLiteral("f"), QStringLiteral("title feminine gender")}};
        QCOMPARE(window.readingExplanations(), titleOnly);
        inspected = false;
        timedOut = false;
        window.reading_->setFocus();
        fallback.start(2000);
        QTimer::singleShot(0, &window, [&] {
            auto *menu = window.findChild<QMenu *>(QStringLiteral("readerContextMenu"));
            QVERIFY(menu);
            auto *action = menu->findChild<QAction *>(QStringLiteral("entryAbbreviations"));
            QVERIFY(action);
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = window.findChild<QDialog *>(QStringLiteral("abbreviationsDialog"));
                QVERIFY(dialog);
                auto *details = dialog->findChild<QTextBrowser *>(QStringLiteral("abbreviationExplanations"));
                QVERIFY(details);
                QVERIFY(details->toPlainText().contains(QStringLiteral("f: title feminine gender")));
                inspected = true;
                dialog->reject();
            });
            menu->setActiveAction(action);
            QTest::keyClick(menu, Qt::Key_Return);
        });
        QTest::keyClick(window.reading_, Qt::Key_F10, Qt::ShiftModifier);
        fallback.stop();
        QVERIFY(!timedOut);
        QVERIFY(inspected);
        QTRY_VERIFY2(window.reading_->hasFocus(), qPrintable(focusContext()));
        QVERIFY(window.openWord(QStringLiteral("Legacy format abbreviation control")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("Legacy format abbreviation control"), 30000);
        QVERIFY(window.readingExplanations().isEmpty());
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


    void completedDictionaryIgnoresStaleCancelActivation() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.loadDataset(fixture_, QStringLiteral("English"), QStringLiteral("language"),
                           false, QStringLiteral("dog"));
        QVERIFY(window.loading_);
        QVERIFY(window.cancelOpening_->isVisible());
        QVERIFY(window.cancelOpening_->isEnabled());
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        QVERIFY(!window.cancelOpening_->isVisible());
        QVERIFY(!window.cancelOpening_->isEnabled());
        QVERIFY(window.cancelLoad_);
        QVERIFY(!window.cancelLoad_->load());
        const auto *api = window.api_.get();
        const unsigned serial = window.loadSerial_;
        const auto cancelled = window.cancelLoad_;
        const QJsonObject entry = window.currentEntry_;
        const QByteArray json = window.currentJson_;
        const QString reading = window.reading_->toPlainText();
        const QString status = window.resultStatus_->text();
        const QString search = window.search_->text();
        const int visitIndex = window.visitIndex_;
        const auto visitCount = window.visits_.size();
        QSettings settings;
        QVariantMap savedSettings;
        for (const QString &key : settings.allKeys()) savedSettings.insert(key, settings.value(key));
        QStringList history;
        for (const auto &word : window.learning_.history()) history.append(word.key);

        QSignalSpy clicked(window.cancelOpening_, &QPushButton::clicked);
        QVERIFY(clicked.isValid());
        window.cancelOpening_->click(); // A disabled ordinary button cannot activate.
        QCOMPARE(clicked.size(), 0);
        // A queued activation can outlive the visible loading affordance. Deliver
        // that actual signal after the new dictionary has already been published.
        QVERIFY(QMetaObject::invokeMethod(window.cancelOpening_, "clicked", Qt::QueuedConnection,
                                          Q_ARG(bool, false)));
        QCoreApplication::sendPostedEvents(window.cancelOpening_, QEvent::MetaCall);
        QCOMPARE(clicked.size(), 1);
        QVERIFY(!window.loading_);
        QCOMPARE(window.api_.get(), api);
        QCOMPARE(window.loadSerial_, serial);
        QVERIFY(window.cancelLoad_ == cancelled);
        QVERIFY(!cancelled->load());
        QCOMPARE(window.currentEntry_, entry);
        QCOMPARE(window.currentJson_, json);
        QCOMPARE(window.reading_->toPlainText(), reading);
        QCOMPARE(window.resultStatus_->text(), status);
        QCOMPARE(window.search_->text(), search);
        QCOMPARE(window.visitIndex_, visitIndex);
        QCOMPARE(window.visits_.size(), visitCount);
        QCOMPARE(title(window), QStringLiteral("dog"));
        QVERIFY(window.search_->isEnabled());
        QVERIFY(!window.cancelOpening_->isVisible());
        QVERIFY(!window.cancelOpening_->isEnabled());
        QVariantMap afterSettings;
        for (const QString &key : settings.allKeys()) afterSettings.insert(key, settings.value(key));
        QCOMPARE(afterSettings, savedSettings);
        QStringList afterHistory;
        for (const auto &word : window.learning_.history()) afterHistory.append(word.key);
        QCOMPARE(afterHistory, history);
    }

    void libraryModalDefersQueuedLoadUntilAfterActualRemoval() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-modal-remove-XXXXXX"));
        QVERIFY(directory.isValid());
        QTemporaryDir rejected(QStringLiteral(".tmp/ui-removed-then-switch-XXXXXX"));
        QVERIFY(rejected.isValid());
        const QString rejectedRoot = QDir(rejected.path()).absolutePath();
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        for (const QString &file : {
                QStringLiteral("languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                QStringLiteral("alias-cases/aliases.wikblb")}) {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QChar('/') + file, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(root, *prepared);
        }
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        const bool nativeDisabled = QApplication::testAttribute(Qt::AA_DontUseNativeDialogs);
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
        auto restoreSources = qScopeGuard([&] {
            QSettings().setValue(QStringLiteral("library/catalogSources"), sources);
            QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, nativeDisabled);
        });
        MainWindow window(root, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QByteArray originalJson = window.currentJson_;
        const QString originalReading = window.reading_->toPlainText();
        QStringList originalHistory;
        for (const auto &entry : window.learning_.history()) originalHistory.append(entry.key);
        window.loadDataset(root, QStringLiteral("English"), QStringLiteral("language"), true, QStringLiteral("Cats"));
        const auto watchers = window.findChildren<QFutureWatcherBase *>();
        QVERIFY(!watchers.isEmpty());
        QPointer<QFutureWatcherBase> pending = watchers.last();
        pending->blockSignals(true);
        QTRY_VERIFY_WITH_TIMEOUT(pending->isFinished(), 30000);
        // Consume the real original notification while blocked, then deliver it once
        // only after a real removal inside Library's nested event loop.
        QCoreApplication::sendPostedEvents(pending.data());
        bool removed = false, deliveredInsideModal = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { dialog->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            auto *installed = dialog->findChild<QTreeWidget *>(QStringLiteral("installedDictionaries"));
            auto *remove = dialog->findChild<QPushButton *>(QStringLiteral("removeDictionary"));
            auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
            QVERIFY(installed && remove && status);
            QTreeWidgetItem *english = nullptr;
            for (int i = 0; i < installed->topLevelItemCount(); ++i)
                if (installed->topLevelItem(i)->text(0) == QStringLiteral("English")) english = installed->topLevelItem(i);
            QVERIFY(english);
            installed->setCurrentItem(english);
            bool confirmationClicked = false;
            QObject confirmationContext;
            QTimer::singleShot(0, &confirmationContext, [&] {
                auto *confirmation = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
                QVERIFY(confirmation);
                auto *yes = confirmation->button(QMessageBox::Yes);
                QVERIFY(yes);
                QTest::mouseClick(yes, Qt::LeftButton);
                confirmationClicked = true;
            });
            QTest::mouseClick(remove, Qt::LeftButton);
            QVERIFY(confirmationClicked);
            QTRY_VERIFY2_WITH_TIMEOUT(status->text().startsWith(QStringLiteral("Removed ")), qPrintable(status->text()), 30000);
            QVERIFY(!QFileInfo::exists(root + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")));
            QVERIFY(QFileInfo::exists(root + QStringLiteral("/aliases.wikblb")));
            removed = true;
            // Editing the original root still invalidates it after selecting a different folder.
            auto *choose = dialog->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
            QVERIFY(choose);
            bool selected = false;
            QTimer deadline;
            deadline.setSingleShot(true);
            QObject::connect(&deadline, &QTimer::timeout, dialog, [dialog] {
                for (auto *picker : dialog->findChildren<QFileDialog *>())
                    if (picker->isVisible()) picker->reject();
            });
            deadline.start(2000);
            QTimer::singleShot(0, dialog, [&] {
                auto *picker = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
                QVERIFY(picker);
                picker->setDirectory(rejectedRoot); picker->selectFile(rejectedRoot);
                selected = QMetaObject::invokeMethod(picker, "accept", Qt::DirectConnection);
            });
            QTest::mouseClick(choose, Qt::LeftButton);
            deadline.stop();
            QVERIFY(selected);
            QVERIFY(pending);
            pending->blockSignals(false);
            QVERIFY(QMetaObject::invokeMethod(pending.data(), "finished", Qt::DirectConnection));
            deliveredInsideModal = true;
            QCOMPARE(window.currentJson_, originalJson);
            QCOMPARE(window.reading_->toPlainText(), originalReading);
            QStringList history;
            for (const auto &entry : window.learning_.history()) history.append(entry.key);
            QCOMPARE(history, originalHistory);
        });
        window.chooseRoot();
        QVERIFY(removed && deliveredInsideModal);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY(!window.api_);
        QVERIFY(window.currentEntry_.isEmpty());
        QVERIFY(window.visits_.isEmpty());
        QCOMPARE(window.visitIndex_, -1);
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QVERIFY(window.currentEntry_.isEmpty() || !window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("followed")).toBool());
    }

    void entryDataIsLazyExactPlainTextAndFollowsNavigation() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(900, 700); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.entryTabs_->currentWidget(), window.reading_);
        QVERIFY(window.json_->document()->isEmpty());
        QCOMPARE(window.json_->document()->blockCount(), 1);
        QVERIFY(window.json_->isReadOnly());
        QCOMPARE(window.json_->accessibleName(), QStringLiteral("Entry data"));
        QVERIFY(qobject_cast<QPlainTextDocumentLayout *>(window.json_->document()->documentLayout()));
        const QString catJson = QString::fromUtf8(window.currentJson_);
        const QString readingBefore = window.reading_->toPlainText();
        QVERIFY(!catJson.isEmpty());
        auto *tabs = window.entryTabs_->tabBar();
        tabs->setFocus(Qt::TabFocusReason);
        QTest::keyClick(tabs, Qt::Key_Right);
        QTest::keyClick(tabs, Qt::Key_Right);
        QCOMPARE(window.entryTabs_->currentWidget(), window.json_);
        QCOMPARE(window.json_->toPlainText(), catJson);
        QCOMPARE(QJsonDocument::fromJson(window.json_->toPlainText().toUtf8()), QJsonDocument::fromJson(window.currentJson_));
        QTest::keyClick(tabs, Qt::Key_Tab);
        QTRY_VERIFY(window.json_->hasFocus());
        QVERIFY(window.json_->textInteractionFlags().testFlag(Qt::TextSelectableByKeyboard));
        QVERIFY(!window.json_->textInteractionFlags().testFlag(Qt::TextEditable));
        auto *jsonScroll = window.json_->verticalScrollBar();
        QVERIFY(jsonScroll->maximum() > jsonScroll->minimum());
        QTest::keyClick(window.json_, Qt::Key_End, Qt::ControlModifier);
        QCOMPARE(window.json_->textCursor().position(), window.json_->document()->characterCount() - 1);
        // Cursor visibility need not consume the scrollbar's trailing document margin.
        QTRY_VERIFY(window.json_->viewport()->rect().contains(window.json_->cursorRect()));
        QVERIFY(jsonScroll->value() > jsonScroll->minimum());
        QTest::keyClick(window.json_, Qt::Key_Home, Qt::ControlModifier);
        QCOMPARE(window.json_->textCursor().position(), 0);
        QTRY_COMPARE(jsonScroll->value(), jsonScroll->minimum());
        QVERIFY(window.json_->viewport()->rect().contains(window.json_->cursorRect()));
        QTest::keyClick(window.json_, Qt::Key_End, Qt::ControlModifier | Qt::ShiftModifier);
        QCOMPARE(window.json_->textCursor().selectionStart(), 0);
        QCOMPARE(window.json_->textCursor().selectionEnd(), window.json_->document()->characterCount() - 1);
        QCOMPARE(window.json_->textCursor().selectedText().replace(QChar::ParagraphSeparator, QLatin1Char('\n')), catJson);
        QTest::keyClick(window.json_, Qt::Key_C, Qt::ControlModifier);
        QCOMPARE(QApplication::clipboard()->text(), catJson);
        QTest::keyClicks(window.json_, "must remain read only");
        QCOMPARE(window.json_->toPlainText(), catJson);
        QSignalSpy textChanges(window.json_->document(), &QTextDocument::contentsChanged);
        QTest::keyClick(window.json_, Qt::Key_Backtab, Qt::ShiftModifier);
        QTRY_VERIFY(tabs->hasFocus());
        QTest::keyClick(tabs, Qt::Key_Left);
        QTest::keyClick(tabs, Qt::Key_Left);
        QCOMPARE(window.entryTabs_->currentWidget(), window.reading_);
        QCOMPARE(window.reading_->toPlainText(), readingBefore);
        QTest::keyClick(tabs, Qt::Key_Right);
        QTest::keyClick(tabs, Qt::Key_Right);
        QCOMPARE(window.json_->toPlainText(), catJson);
        QCOMPARE(textChanges.count(), 0);
        QVERIFY(window.openWord(QStringLiteral("dog")));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        QCOMPARE(window.entryTabs_->currentWidget(), window.reading_);
        QVERIFY(window.json_->document()->isEmpty());
        const QString dogJson = QString::fromUtf8(window.currentJson_);
        QVERIFY(dogJson != catJson);
        QTest::keyClick(tabs, Qt::Key_Right);
        QTest::keyClick(tabs, Qt::Key_Right);
        QCOMPARE(window.json_->toPlainText(), dogJson);
        QVERIFY(!window.openWord(QStringLiteral("__missing_entry_data_control__")));
        QCOMPARE(QString::fromUtf8(window.currentJson_), dogJson);
        QCOMPARE(window.json_->toPlainText(), dogJson);
    }

    void removingLastDictionaryClearsVisibleEntryAndSearchState_data() {
        QTest::addColumn<bool>("cancelReload");
        QTest::newRow("reload-managed-empty") << false;
        QTest::newRow("reload-cancelled-empty") << true;
    }

    void removingLastDictionaryClearsVisibleEntryAndSearchState() {
        QFETCH(bool, cancelReload);
        QTemporaryDir directory(QStringLiteral(".tmp/ui-last-dictionary-remove-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QStringLiteral(
                "/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(root, *prepared);
        }
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        MainWindow window(root, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.json_->toPlainText().isEmpty());
        QVERIFY(window.results_->count() > 0);
        QVERIFY(window.sections_->count() > 1);
        QVERIFY(window.sections_->isEnabled());
        QVERIFY(window.bookmark_->isEnabled());
        const QString query = window.search_->text();
        QStringList history;
        for (const auto &entry : window.learning_.history()) history.append(entry.key);
        window.entryTabs_->setCurrentWidget(window.json_);
        QCOMPARE(window.json_->toPlainText(), QString::fromUtf8(window.currentJson_));
        QVERIFY(!window.json_->toPlainText().isEmpty());

        bool removed = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { dialog->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            auto *installed = dialog->findChild<QTreeWidget *>(QStringLiteral("installedDictionaries"));
            auto *remove = dialog->findChild<QPushButton *>(QStringLiteral("removeDictionary"));
            auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
            QVERIFY(installed && remove && status);
            QCOMPARE(installed->topLevelItemCount(), 1);
            QCOMPARE(installed->topLevelItem(0)->text(0), QStringLiteral("English"));
            installed->setCurrentItem(installed->topLevelItem(0));
            bool confirmationClicked = false;
            QObject confirmationContext;
            QTimer::singleShot(0, &confirmationContext, [&] {
                auto *confirmation = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
                QVERIFY(confirmation);
                auto *yes = confirmation->button(QMessageBox::Yes);
                QVERIFY(yes);
                QTest::mouseClick(yes, Qt::LeftButton);
                confirmationClicked = true;
            });
            QTest::mouseClick(remove, Qt::LeftButton);
            QVERIFY(confirmationClicked);
            QTRY_VERIFY2_WITH_TIMEOUT(status->text().startsWith(QStringLiteral("Removed ")), qPrintable(status->text()), 30000);
            QVERIFY(!QFileInfo::exists(root + QStringLiteral(
                "/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")));
            removed = true;
        });
        window.chooseRoot();
        QVERIFY(removed);
        if (cancelReload) {
            // chooseRoot starts the real replacement load before returning; no event-loop delay.
            QVERIFY(window.loading_);
            QVERIFY(!window.api_);
            QVERIFY(window.cancelOpening_->isVisible());
            window.cancelOpening_->click();
        }
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && !window.api_, 30000);
        QTRY_VERIFY_WITH_TIMEOUT(window.findChildren<QFutureWatcherBase *>().isEmpty(), 30000);
        QCoreApplication::processEvents();
        QVERIFY(window.currentEntry_.isEmpty());
        QVERIFY(window.currentJson_.isEmpty());
        QVERIFY(window.json_->toPlainText().isEmpty());
        QCOMPARE(window.search_->text(), query);
        QCOMPARE(window.results_->count(), 0);
        QCOMPARE(window.sections_->count(), 0);
        QVERIFY(!window.sections_->isEnabled());
        QVERIFY(!window.bookmark_->isEnabled());
        QVERIFY(!window.search_->isEnabled());
        QVERIFY(!window.results_->isEnabled());
        QVERIFY(!window.random_->isEnabled());
        QVERIFY(!window.listen_->isEnabled());
        QVERIFY(!window.moreResults_->isEnabled());
        QVERIFY(!window.back_->isEnabled());
        QVERIFY(!window.forward_->isEnabled());
        QCOMPARE(window.title_->toPlainText(), QStringLiteral("Open your dictionaries"));
        QCOMPARE(window.resultStatus_->text(), cancelReload
            ? QStringLiteral("Opening cancelled. Choose a folder to try again.")
            : QStringLiteral("No dictionary open"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Open Library")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        if (!cancelReload) {
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("No dictionaries are installed yet.")));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Could not open")));
            QVERIFY(QFileInfo::exists(root + QStringLiteral("/.desktop-library.json")));
            QFile manifest(root + QStringLiteral("/languages.tsv"));
            QVERIFY(manifest.open(QIODevice::ReadOnly));
            QCOMPARE(manifest.readAll(), QByteArrayLiteral("heading\n"));
            MainWindow reopened(root);
            reopened.show();
            QTRY_VERIFY_WITH_TIMEOUT(!reopened.loading_, 30000);
            QVERIFY(!reopened.api_);
            QVERIFY(reopened.reading_->toPlainText().contains(QStringLiteral("No dictionaries are installed yet.")));
            QVERIFY(!reopened.reading_->toPlainText().contains(QStringLiteral("Could not open")));
        }
        QStringList remainingHistory;
        for (const auto &entry : window.learning_.history()) remainingHistory.append(entry.key);
        QCOMPARE(remainingHistory, history);
    }

    void choosingSameFolderReloadsExternallyReplacedDictionary() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-same-folder-reload-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString base = QDir(directory.path()).absolutePath();
        QVERIFY(prepareCaseTitleFixture(fixture_, base, {QStringLiteral("cat")}));
        const QString root = base + QStringLiteral("/library");
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        const bool nativeDisabled = QApplication::testAttribute(Qt::AA_DontUseNativeDialogs);
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
        auto restore = qScopeGuard([&] {
            QSettings().setValue(QStringLiteral("library/catalogSources"), sources);
            QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, nativeDisabled);
        });
        MainWindow window(root, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(!window.searchTitles_.contains(QStringLiteral("newterm")));
        const unsigned serial = window.loadSerial_;
        // The same ordinary installer transaction replaces bytes outside this window.
        QVERIFY(prepareCaseTitleFixture(fixture_, base, {QStringLiteral("cat"), QStringLiteral("newterm")}));
        bool selected = false;
        QTimer::singleShot(0, &window, [&] {
            auto *library = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(library && library->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { library->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!library->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            auto *choose = library->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
            QVERIFY(choose);
            // A failed assertion in the callback must not strand the nested chooser.
            QTimer chooserDeadline;
            chooserDeadline.setSingleShot(true);
            QObject::connect(&chooserDeadline, &QTimer::timeout, library, [library] {
                for (auto *picker : library->findChildren<QFileDialog *>())
                    if (picker->isVisible()) picker->reject();
            });
            chooserDeadline.start(2000);
            auto stopDeadline = qScopeGuard([&] { chooserDeadline.stop(); });
            QTimer::singleShot(0, library, [&] {
                auto *picker = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
                QVERIFY(picker);
                picker->setDirectory(root);
                picker->selectFile(root);
                selected = QMetaObject::invokeMethod(picker, "accept", Qt::DirectConnection);
            });
            QTest::mouseClick(choose, Qt::LeftButton);
            QVERIFY(selected);
        });
        window.chooseRoot();
        QVERIFY(selected);
        QVERIFY(window.loadSerial_ > serial);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.searchTitles_.contains(QStringLiteral("newterm")));
        window.search_->setText(QStringLiteral("newterm"));
        window.refreshSearch();
        QCOMPARE(window.results_->count(), 1);
        window.search_->setFocus();
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("newterm"));
        QVERIFY(!window.currentEntry_.isEmpty());
        QVERIFY(!window.reading_->toPlainText().isEmpty());
    }

    void failedLibraryFolderSelectionPreservesReaderAndNavigation() {
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        const bool nativeDisabled = QApplication::testAttribute(Qt::AA_DontUseNativeDialogs);
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
        auto restore = qScopeGuard([&] {
            QSettings().setValue(QStringLiteral("library/catalogSources"), sources);
            QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, nativeDisabled);
        });
        for (const bool malformed : {false, true}) {
            QTemporaryDir candidate(QStringLiteral(".tmp/ui-rejected-root-XXXXXX"));
            QVERIFY(candidate.isValid());
            const QString rejectedRoot = QDir(candidate.path()).absolutePath();
            if (malformed) {
                QFile manifest(rejectedRoot + QStringLiteral("/languages.tsv"));
                QVERIFY(manifest.open(QIODevice::WriteOnly));
                QCOMPARE(manifest.write("invalid manifest\n"), qint64(17));
            }
            MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
            QVERIFY(window.openWord(QStringLiteral("dog")));
            QTRY_COMPARE(title(window), QStringLiteral("dog"));
            const QByteArray json = window.currentJson_;
            const QString reading = window.reading_->toPlainText();
            window.saveVisit();
            const auto visits = window.visits_;
            const auto collapsed = window.collapsedSections_;
            const int scroll = window.reading_->verticalScrollBar()->value();
            const int visitIndex = window.visitIndex_;
            const QString rootSetting = QSettings().value(QStringLiteral("reader/root")).toString();
            bool selected = false;
            QTimer::singleShot(0, &window, [&] {
                auto *library = qobject_cast<QDialog *>(QApplication::activeModalWidget());
                QVERIFY(library && library->objectName() == QStringLiteral("libraryDialog"));
                auto close = qScopeGuard([&] { library->done(QDialog::Rejected); });
                QTRY_VERIFY_WITH_TIMEOUT(!library->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
                auto *choose = library->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
                QVERIFY(choose);
                QTimer deadline;
                deadline.setSingleShot(true);
                QObject::connect(&deadline, &QTimer::timeout, library, [library] {
                    for (auto *picker : library->findChildren<QFileDialog *>())
                        if (picker->isVisible()) picker->reject();
                });
                deadline.start(2000);
                QTimer::singleShot(0, library, [&] {
                    auto *picker = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
                    QVERIFY(picker);
                    picker->setDirectory(rejectedRoot); picker->selectFile(rejectedRoot);
                    selected = QMetaObject::invokeMethod(picker, "accept", Qt::DirectConnection);
                });
                QTest::mouseClick(choose, Qt::LeftButton);
                deadline.stop();
                QVERIFY(selected);
            });
            window.chooseRoot();
            QVERIFY(selected);
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            QVERIFY(window.api_ && window.search_->isEnabled());
            QCOMPARE(window.api_->root(), fixture_);
            QCOMPARE(window.currentJson_, json);
            QCOMPARE(window.reading_->toPlainText(), reading);
            QCOMPARE(window.visitIndex_, visitIndex);
            QCOMPARE(window.visits_.size(), visits.size());
            for (qsizetype i = 0; i < visits.size(); ++i) {
                QCOMPARE(window.visits_[i].title, visits[i].title);
                QCOMPARE(window.visits_[i].language, visits[i].language);
                QCOMPARE(window.visits_[i].kind, visits[i].kind);
                QCOMPARE(window.visits_[i].scroll, visits[i].scroll);
                QCOMPARE(window.visits_[i].collapsed, visits[i].collapsed);
            }
            QCOMPARE(window.collapsedSections_, collapsed);
            QCOMPARE(window.reading_->verticalScrollBar()->value(), scroll);
            QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), rootSetting);
            QVERIFY(window.resultStatus_->text() == QStringLiteral("Could not open the selected dictionary. Your current dictionary is still open."));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-rejected-root-%1.png").arg(malformed ? QStringLiteral("invalid") : QStringLiteral("empty"))));
            window.navigate(-1);
            QTRY_COMPARE(title(window), QStringLiteral("cat"));
        }
    }

    void libraryWorkerDistinguishesUnrestoredMutationFromRestoredErrors() {
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        // The worker fixture injects the typed result after real filesystem recovery attempts.
        // The same message on ordinary failures must not mark a root as changed.
        for (const int mode : {0, 1, 2}) { // validation, restored error, unrestored error
            QTemporaryDir directory(QStringLiteral(".tmp/ui-recovery-status-XXXXXX"));
            QTemporaryDir recovery(QStringLiteral(".tmp/ui-recovery-files-XXXXXX"));
            QVERIFY(directory.isValid() && recovery.isValid());
            const QString root = QDir(directory.path()).absolutePath();
            const QString backup = QDir(recovery.path()).absoluteFilePath(QStringLiteral("dictionary.wikblb"));
            std::atomic_bool cancelled = false;
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"), {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(root, *prepared);
            const QString dictionary = prepared->dictionary.path;
            QFile original(dictionary);
            QVERIFY(original.open(QIODevice::ReadOnly));
            const QByteArray originalBytes = original.readAll();
            QVERIFY(!originalBytes.isEmpty());
            original.close();
            MainWindow window(root, QStringLiteral("cat")); window.show();
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
            QVERIFY(window.openWord(QStringLiteral("dog")));
            QTRY_COMPARE(title(window), QStringLiteral("dog"));
            const QByteArray json = window.currentJson_;
            const QString reading = window.reading_->toPlainText();
            const int visitIndex = window.visitIndex_;
            const qsizetype visitCount = window.visits_.size();
            bool completed = false;
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = static_cast<LibraryDialog *>(QApplication::activeModalWidget());
                QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
                auto closeOnSetupFailure = qScopeGuard([dialog] { dialog->done(QDialog::Rejected); });
                QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
                dialog->setBusy(true, QStringLiteral("Testing recovery status"));
                dialog->runWorker([dictionary, backup, mode] {
                    const char *message = "The dictionary could not be restored.";
                    if (mode != 0) {
                        if (!QFile::rename(dictionary, backup)) throw std::runtime_error("Recovery fixture could not move the dictionary");
                        if (mode == 1) {
                            if (!QFile::rename(backup, dictionary)) throw std::runtime_error("Recovery fixture could not restore the dictionary");
                        } else {
                            if (!QDir().mkpath(dictionary)) throw std::runtime_error("Recovery fixture could not block the original path");
                            if (QFile::rename(backup, dictionary)) throw std::runtime_error("Recovery fixture unexpectedly restored the dictionary");
                            throw LibraryStorage::UnrestoredMutation(message);
                        }
                    }
                    throw std::runtime_error(message);
                }, [&, dialog](const QString &error) {
                    auto close = qScopeGuard([dialog] { dialog->done(QDialog::Rejected); });
                    dialog->finishOperation(error, true);
                    QCOMPARE(error, QStringLiteral("The dictionary could not be restored."));
                    QCOMPARE(dialog->libraryChanged(), mode == 2);
                    QCOMPARE(dialog->originalRootChanged(), mode == 2);
                    auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
                    auto *choose = dialog->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
                    auto *importButton = dialog->findChild<QPushButton *>(QStringLiteral("importDictionary"));
                    auto *cancel = dialog->findChild<QPushButton *>(QStringLiteral("cancelLibraryOperation"));
                    auto *progress = dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"));
                    QVERIFY(status && choose && importButton && cancel && progress);
                    QCOMPARE(status->text(), QStringLiteral("Could not finish: The dictionary could not be restored."));
                    QVERIFY(choose->isEnabled() && importButton->isEnabled());
                    QVERIFY(!cancel->isVisible() && !progress->isVisible());
                    dialog->activateWindow();
                    choose->setFocus();
                    QTRY_VERIFY(choose->hasFocus());
                    for (int steps = 0; steps < 16 && !importButton->hasFocus(); ++steps)
                        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Tab);
                    QTRY_VERIFY(importButton->hasFocus());
                    const QString suffix = mode == 0 ? QStringLiteral("validation")
                        : mode == 1 ? QStringLiteral("restored") : QStringLiteral("unrestored");
                    QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-worker-recovery-%1.png").arg(suffix)));
                    QTest::keyClick(importButton, Qt::Key_Escape);
                    QTRY_VERIFY(!dialog->isVisible());
                    completed = true;
                });
                closeOnSetupFailure.dismiss();
            });
            window.chooseRoot();
            QVERIFY(completed);
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            if (mode == 2) {
                QVERIFY(QFileInfo(dictionary).isDir() && QFileInfo(backup).isFile());
                QFile retained(backup);
                QVERIFY(retained.open(QIODevice::ReadOnly));
                QCOMPARE(retained.readAll(), originalBytes);
                QVERIFY(!window.api_ && window.currentEntry_.isEmpty() && window.currentJson_.isEmpty());
                QVERIFY(window.visits_.isEmpty());
                QCOMPARE(window.visitIndex_, -1);
                QVERIFY(!window.back_->isEnabled());
                QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Could not open this dictionary.")));
            } else {
                QVERIFY(QFileInfo(dictionary).isFile() && !QFileInfo::exists(backup));
                QFile restored(dictionary);
                QVERIFY(restored.open(QIODevice::ReadOnly));
                QCOMPARE(restored.readAll(), originalBytes);
                QVERIFY(window.api_ && window.search_->isEnabled());
                QCOMPARE(window.currentJson_, json);
                QCOMPARE(window.reading_->toPlainText(), reading);
                QCOMPARE(window.visitIndex_, visitIndex);
                QCOMPARE(window.visits_.size(), visitCount);
                window.navigate(-1);
                QTRY_COMPARE(title(window), QStringLiteral("cat"));
            }
        }
    }

    void unchangedLibraryClosePreservesDisplayedEntry() {
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QByteArray json = window.currentJson_;
        const QString reading = window.reading_->toPlainText();
        const unsigned serial = window.loadSerial_;
        QTimer::singleShot(0, &window, [] {
            if (auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget())) dialog->done(QDialog::Rejected);
        });
        window.chooseRoot();
        QCOMPARE(window.currentJson_, json);
        QCOMPARE(window.reading_->toPlainText(), reading);
        QCOMPARE(window.loadSerial_, serial);
        QVERIFY(!window.loading_ && window.api_ && window.search_->isEnabled());
    }

    void unchangedLibraryClosePreservesPendingInitialWord_data() {
        QTest::addColumn<bool>("queued");
        QTest::newRow("completed-result-held") << true;
        QTest::newRow("unfinished-worker") << false;
    }
    void unchangedLibraryClosePreservesPendingInitialWord() {
        QFETCH(bool, queued);
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        QThreadPool *pool = QThreadPool::globalInstance();
        const int originalMaximum = pool->maxThreadCount();
        QSemaphore entered, release;
        QFuture<void> blocker;
        if (!queued) {
            pool->setMaxThreadCount(1);
            blocker = QtConcurrent::run([&] { entered.release(); release.acquire(); });
        }
        auto unblock = qScopeGuard([&] {
            if (!queued) { release.release(); blocker.waitForFinished(); pool->setMaxThreadCount(originalMaximum); }
        });
        if (!queued) QVERIFY(entered.tryAcquire(1, 30000));
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QPointer<QFutureWatcherBase> pending;
        if (queued) {
            const auto watchers = window.findChildren<QFutureWatcherBase *>();
            QVERIFY(!watchers.isEmpty()); pending = watchers.last();
            pending->blockSignals(true);
            QTRY_VERIFY_WITH_TIMEOUT(pending->isFinished(), 30000);
            QCoreApplication::sendPostedEvents(pending.data());
        }
        bool inside = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { dialog->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            if (queued) {
                QVERIFY(pending); pending->blockSignals(false);
                QVERIFY(QMetaObject::invokeMethod(pending.data(), "finished", Qt::DirectConnection));
            }
            inside = true;
            QVERIFY(window.loading_ && !window.api_ && window.currentEntry_.isEmpty());
        });
        window.chooseRoot();
        QVERIFY(inside);
        if (!queued) {
            QVERIFY(window.loading_ && !window.api_);
            // Existing held worker makes this loading state deterministic.
            window.resize(780, 480);
            QCoreApplication::processEvents();
            auto *sidebar = window.findChild<QScrollArea *>(QStringLiteral("readerSidebarScroll"));
            QVERIFY(sidebar);
            QVERIFY(window.results_->height() >= window.results_->minimumSizeHint().height());
            QPushButton *settings = nullptr;
            for (QPushButton *button : sidebar->findChildren<QPushButton *>()) {
                QVERIFY(button->height() >= button->minimumSizeHint().height());
                QVERIFY(button->width() >= button->minimumSizeHint().width());
                if (button->text() == QStringLiteral("Settings")) settings = button;
            }
            QVERIFY(settings);
            QCOMPARE(sidebar->horizontalScrollBar()->maximum(), 0);
            sidebar->verticalScrollBar()->setValue(0);
            QCoreApplication::processEvents();
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-held-loading.png")));
            window.activateWindow();
            window.cancelOpening_->setFocus();
            QTRY_VERIFY(window.cancelOpening_->hasFocus());
            for (int steps = 0; steps < 24 && !settings->hasFocus(); ++steps)
                QTest::keyClick(QApplication::focusWidget(), Qt::Key_Tab);
            QTRY_VERIFY(settings->hasFocus());
            QTRY_VERIFY(sidebar->viewport()->rect().contains(QRect(settings->mapTo(sidebar->viewport(), QPoint()), settings->size())));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-held-loading-keyboard.png")));
            release.release(); blocker.waitForFinished();
        }
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.originRoot_, QFileInfo(fixture_).canonicalFilePath());
        QCOMPARE(window.originEdition_, LibraryStorage::editionIdentity(fixture_));
        QVERIFY(window.search_->isEnabled());
        QVERIFY(!window.cancelOpening_->isVisible());
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

    void searchAliasFragmentUnfoldsDestinationAndExplicitLinkWins() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-alias-fragment-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        const auto progress = [](const QString &, qint64, qint64) {};
        for (const QString &file : {
                QStringLiteral("fragment-cases/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                QStringLiteral("alias-cases/aliases.wikblb")}) {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QChar('/') + file, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *prepared);
        }
        MainWindow window(root); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.learning_.setCollapseEtymology(true);
        window.search_->setText(QStringLiteral("History of cat"));
        QTRY_COMPARE(window.results_->count(), 1);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const int etymologyChoice = window.sections_->findText(QStringLiteral("Etymology"));
        QVERIFY(etymologyChoice >= 0);
        const int etymologySection = window.sections_->itemData(etymologyChoice).toInt();
        QCOMPARE(window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("fragment")).toString(), QStringLiteral("Etymology"));
        QVERIFY(!window.collapsedSections_.contains(etymologySection));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Historical source.")));
        QVERIFY(window.reading_->verticalScrollBar()->value() > 0);

        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Alias noun destination")},
            {QStringLiteral("target"), QStringLiteral("History of cat#Noun")}}});
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:History%20of%20cat%23Noun")));
        QCOMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.collapsedSections_.contains(etymologySection));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("A small animal.")));

        QVERIFY(window.openWord(QStringLiteral("History of cat"), QStringLiteral("No such section")));
        QVERIFY(window.collapsedSections_.contains(etymologySection)); // An explicit missing fragment never falls back to the alias fragment.
        QVERIFY(window.openWord(QStringLiteral("History of cat"), QStringLiteral("")));
        QVERIFY(window.collapsedSections_.contains(etymologySection)); // Explicit empty fragments also suppress alias fallback.
        QVERIFY(window.openWord(QStringLiteral("Cats")));
        QVERIFY(window.collapsedSections_.contains(etymologySection)); // Fragment-free aliases retain normal folding.
        QVERIFY(window.openWord(QStringLiteral("Loop A")));
        QCOMPARE(title(window), QStringLiteral("Loop B"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("kind")).toString(), QStringLiteral("alias")); // Still one edge.
    }

    void repeatedOwnerLanguageSectionsKeepOneMenuChoiceAndOriginalAnchors() {
        MainWindow window(fixture_); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("title"), QStringLiteral("YYA"));
        entry.insert(QStringLiteral("kind"), QStringLiteral("language"));
        entry.insert(QStringLiteral("language"), QStringLiteral("Finnish"));
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{});
        const QJsonArray overview{QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("See also: ")}},
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("yya")}, {QStringLiteral("target"), QStringLiteral("yya")}}
            }}
        }};
        const auto section = [](int level, const QString &title, const QJsonArray &blocks = QJsonArray{}) {
            return QJsonObject{{QStringLiteral("level"), level}, {QStringLiteral("title"), title}, {QStringLiteral("blocks"), blocks}};
        };
        // Current YYA has an owner-language overview, an empty owner heading, and these lexical sections.
        entry.insert(QStringLiteral("sections"), QJsonArray{
            section(2, QStringLiteral("Finnish"), overview), section(2, QStringLiteral("Finnish")),
            section(3, QStringLiteral("Etymology")), section(3, QStringLiteral("Proper noun")), section(4, QStringLiteral("Declension")),
            section(3, QStringLiteral("Etymology")), // Ordinary duplicate headings retain both original indices.
            section(2, QStringLiteral("English")), section(2, QStringLiteral("English")) // Non-owner L2 duplicates also remain.
        });
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QStringList choices; QList<int> indices;
        for (int i = 1; i < window.sections_->count(); ++i) {
            choices.append(window.sections_->itemText(i)); indices.append(window.sections_->itemData(i).toInt());
        }
        QCOMPARE(choices, QStringList({QStringLiteral("Finnish"), QStringLiteral("Etymology"), QStringLiteral("Proper noun"),
            QStringLiteral("Declension"), QStringLiteral("Etymology"), QStringLiteral("English"), QStringLiteral("English")}));
        QCOMPARE(indices, QList<int>({0, 2, 3, 4, 5, 6, 7}));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("English")), 2);
        QVERIFY(window.reading_->document()->find(QStringLiteral("Finnish")).isNull());
        const QTextCursor firstEnglish = window.reading_->document()->find(QStringLiteral("English"));
        const QTextCursor secondEnglish = window.reading_->document()->find(QStringLiteral("English"), firstEnglish);
        QVERIFY(!firstEnglish.isNull() && !secondEnglish.isNull());
        QCOMPARE(firstEnglish.charFormat().anchorHref(), QStringLiteral("section:6"));
        QCOMPARE(secondEnglish.charFormat().anchorHref(), QStringLiteral("section:7"));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:6")));
        QVERIFY(window.collapsedSections_.contains(6));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("See also: yya")), 1);
        QVERIFY(window.reading_->toHtml().contains(QStringLiteral("dict:yya")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-0")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-1")));
        window.collapsedSections_.insert(0); window.refreshReading();
        window.jumpToFragment(QStringLiteral("Finnish"));
        QVERIFY(!window.collapsedSections_.contains(0));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("See also: yya")));
        for (int index : {2, 5, 6, 7}) window.collapsedSections_.insert(index);
        window.refreshReading();
        window.jumpToFragment(QStringLiteral("Etymology"));
        QVERIFY(window.collapsedSections_.contains(2) && window.collapsedSections_.contains(5));
        window.jumpToFragment(QStringLiteral("English"));
        QVERIFY(window.collapsedSections_.contains(6) && window.collapsedSections_.contains(7));

        // A same-label nested heading is not an equivalent owner-language destination.
        QJsonObject nestedOwnerEntry = entry;
        QJsonArray nestedOwnerSections = entry.value(QStringLiteral("sections")).toArray();
        QJsonObject nestedOwnerSection = nestedOwnerSections[0].toObject();
        QJsonArray nestedOwnerBlocks = overview;
        nestedOwnerBlocks.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")},
            {QStringLiteral("level"), 3}, {QStringLiteral("spans"), QJsonArray{
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("Finnish")}}}}});
        nestedOwnerSection.insert(QStringLiteral("blocks"), nestedOwnerBlocks);
        nestedOwnerSections[0] = nestedOwnerSection;
        nestedOwnerEntry.insert(QStringLiteral("sections"), nestedOwnerSections);
        response.insert(QStringLiteral("entries"), QJsonArray{nestedOwnerEntry});
        window.renderResponse(QJsonDocument(response).toJson());
        window.collapsedSections_.insert(0); window.collapsedSections_.insert(1);
        window.refreshReading(); window.jumpToFragment(QStringLiteral("Finnish"));
        QVERIFY(window.collapsedSections_.contains(0) && window.collapsedSections_.contains(1));

        // A compiled owner heading is authoritative even when the menu coalesces owner labels.
        QJsonArray explicitSections = entry.value(QStringLiteral("sections")).toArray();
        QJsonObject actualOwnerHeading = explicitSections[1].toObject();
        actualOwnerHeading.insert(QStringLiteral("anchor"), QStringLiteral("Finnish"));
        explicitSections[1] = actualOwnerHeading;
        entry.insert(QStringLiteral("sections"), explicitSections);
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        window.collapsedSections_.insert(0); window.collapsedSections_.insert(1);
        window.refreshReading(); window.jumpToFragment(QStringLiteral("Finnish"));
        QVERIFY(window.collapsedSections_.contains(0));
        QVERIFY(!window.collapsedSections_.contains(1));
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

    void invalidCompiledImportPreservesReaderAndHistory() {
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QTemporaryDir directory(QStringLiteral(".tmp/ui-invalid-compiled-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.filePath(QStringLiteral("library"))).absolutePath();
        std::atomic_bool cancelled = false;
        auto prepared = LibraryStorage::prepareImport(root,
            fixture_ + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
            {}, -1, cancelled, [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        QFile original(prepared->dictionary.path); QVERIFY(original.open(QIODevice::ReadOnly));
        const QByteArray originalBytes = original.readAll(); original.close();
        QFile manifest(root + QStringLiteral("/languages.tsv")); QVERIFY(manifest.open(QIODevice::ReadOnly));
        const QByteArray manifestBytes = manifest.readAll(); manifest.close();
        QFile fixture(fixture_ + QStringLiteral("/alias-cases/aliases.wikblb"));
        QVERIFY(fixture.open(QIODevice::ReadOnly));
        QByteArray aliasBytes = fixture.readAll();
        const qsizetype presentation = aliasBytes.indexOf("DPR2");
        QVERIFY(presentation >= 0 && presentation + 8 <= aliasBytes.size());
        for (qsizetype i = 4; i < 8; ++i) aliasBytes[presentation + i] = char(255);
        // A valid first record, then a framed but incomplete second presentation.
        QByteArray ordinary = QByteArrayLiteral("WIKBLB08") + char(1) + QByteArray("en\0English\0apple\0", 17);
        ordinary.append(char(32)); ordinary.append("DPR2", 4); ordinary.append(QByteArray(28, '\0'));
        ordinary.append("banana", 6); ordinary.append('\0'); ordinary.append(char(4)); ordinary.append("DPR2", 4);
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        MainWindow window(root, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QVERIFY(window.openWord(QStringLiteral("dog")));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        window.saveVisit();
        const QByteArray json = window.currentJson_;
        const QString reading = window.reading_->toPlainText();
        const auto visits = window.visits_;
        const int visitIndex = window.visitIndex_;
        for (const bool alias : {false, true}) {
            const QString source = directory.filePath(alias ? QStringLiteral("bad-alias.wikblb") : QStringLiteral("bad-later-record.wikblb"));
            QFile candidate(source); QVERIFY(candidate.open(QIODevice::WriteOnly));
            const QByteArray bytes = alias ? aliasBytes : ordinary;
            QCOMPARE(candidate.write(bytes), bytes.size()); candidate.close();
            bool completed = false;
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = static_cast<LibraryDialog *>(QApplication::activeModalWidget());
                QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
                auto close = qScopeGuard([dialog] { dialog->done(QDialog::Rejected); });
                QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
                auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
                auto *progress = dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"));
                auto *importButton = dialog->findChild<QPushButton *>(QStringLiteral("importDictionary"));
                QVERIFY(status && progress && importButton);
                dialog->startImport(source); // Real import worker and native semantic decoder, no injected refusal.
                const QString invalidMessage = QStringLiteral("Could not import this dictionary. The file contains invalid entry data.");
                QTRY_VERIFY2_WITH_TIMEOUT(status->text() == invalidMessage && !progress->isVisible(), qPrintable(status->text()), 30000);
                QVERIFY(status->property("validationDiagnostic").toString().contains(QStringLiteral("InvalidPresentation")));
                QVERIFY(!status->text().contains(QStringLiteral("InvalidPresentation")));
                auto *guidance = dialog->findChild<QLabel *>(QStringLiteral("availableDictionariesSummary"));
                auto *addSource = dialog->findChild<QPushButton *>(QStringLiteral("addCatalogueSource"));
                auto *refresh = dialog->findChild<QPushButton *>(QStringLiteral("refreshCatalogues"));
                QVERIFY(guidance && addSource && refresh);
                QCOMPARE(guidance->text(), QStringLiteral("Add a source to browse available dictionaries."));
                QVERIFY(addSource->isEnabled() && !refresh->isEnabled());
                QVERIFY(importButton->isEnabled());
                QVERIFY(!dialog->libraryChanged() && !dialog->originalRootChanged());
                QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-semantic-import-%1-plain-error.png").arg(alias ? QStringLiteral("alias") : QStringLiteral("later-record"))));
                completed = true;
            });
            window.chooseRoot();
            QVERIFY(completed);
            QVERIFY(!window.loading_ && window.api_ && window.search_->isEnabled());
            QCOMPARE(window.api_->root(), root);
            QCOMPARE(window.currentJson_, json);
            QCOMPARE(window.reading_->toPlainText(), reading);
            QCOMPARE(window.visitIndex_, visitIndex);
            QCOMPARE(window.visits_.size(), visits.size());
            for (qsizetype i = 0; i < visits.size(); ++i) {
                QCOMPARE(window.visits_[i].title, visits[i].title);
                QCOMPARE(window.visits_[i].language, visits[i].language);
                QCOMPARE(window.visits_[i].kind, visits[i].kind);
                QCOMPARE(window.visits_[i].scroll, visits[i].scroll);
                QCOMPARE(window.visits_[i].collapsed, visits[i].collapsed);
            }
            QVERIFY(original.open(QIODevice::ReadOnly)); QCOMPARE(original.readAll(), originalBytes); original.close();
            QVERIFY(manifest.open(QIODevice::ReadOnly)); QCOMPARE(manifest.readAll(), manifestBytes); manifest.close();
            QCOMPARE(LibraryStorage::installed(root).size(), qsizetype(1));
            QVERIFY(!QFileInfo::exists(root + QStringLiteral("/aliases.wikblb")));
        }
        window.navigate(-1);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
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

    void explicitLanguageFragmentSelectsInstalledOwnerAndPreservesNavigation() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-language-fragments-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString word = QString::fromUtf8("κρώζω");
        const QString modernOnly = QStringLiteral("modern-only");
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(), {word, modernOnly},
            QByteArrayLiteral("el"), QByteArrayLiteral("Greek")));
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(), {word},
            QByteArrayLiteral("grc"), QByteArrayLiteral("Ancient Greek"), true));
        const QString root = directory.path() + QStringLiteral("/library");
        QFile edition(root + QStringLiteral("/.desktop-edition"));
        QVERIFY(edition.open(QIODevice::WriteOnly));
        const QByteArray editionBytes = QByteArrayLiteral("enwiktionary-20261001\n");
        QCOMPARE(edition.write(editionBytes), qint64(editionBytes.size()));
        edition.close();
        QSettings().setValue(QStringLiteral("reader/language"), QStringLiteral("Greek"));
        MainWindow window(root, word); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), word);
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        const QString originalRoot = window.originRoot_;
        const QString originalEdition = window.originEdition_;
        const QString greekKey = window.savedWord(window.currentEntry_).key;
        const auto follow = [&](const QString &target) {
            QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(word)).object();
            QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
            QJsonArray preamble = entry.value(QStringLiteral("preamble_spans")).toArray();
            preamble.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), QStringLiteral("Follow owner or section")}, {QStringLiteral("target"), target}});
            entry.insert(QStringLiteral("preamble_spans"), preamble);
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson(), false);
            return clickAnchor(window.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target)));
        };
        QTRY_VERIFY(window.search_->hasFocus()); // Ordinary dataset opening keeps search ready.
        window.reading_->setFocus();
        QTRY_VERIFY(window.reading_->hasFocus());
        QVERIFY(follow(word + QStringLiteral("#Ancient_Greek")));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Ancient Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        QCOMPARE(window.currentEntry_.value(QStringLiteral("language")).toString(), QStringLiteral("Ancient Greek"));
        QTRY_VERIFY(window.reading_->hasFocus()); // The link destination retains reader focus.
        QCOMPARE(window.language_->currentText(), QStringLiteral("Ancient Greek"));
        QCOMPARE(window.originRoot_, originalRoot);
        QCOMPARE(window.originEdition_, originalEdition);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A river animal.")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QVERIFY(window.savedWord(window.currentEntry_).key != greekKey);
        QVERIFY(window.back_->isEnabled());
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        QCOMPARE(window.savedWord(window.currentEntry_).key, greekKey);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Ancient Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A river animal.")));

        const unsigned serial = window.loadSerial_;
        QVERIFY(follow(word + QStringLiteral("#Etymology")));
        QCOMPARE(window.loadSerial_, serial);
        QCOMPARE(window.api_->language(), QStringLiteral("Ancient Greek"));
        const int row = window.sections_->findText(QStringLiteral("Etymology"));
        QVERIFY(row >= 0);
        QVERIFY(!window.collapsedSections_.contains(window.sections_->itemData(row).toInt()));
        QTRY_VERIFY(window.reading_->hasFocus()); // Same-owner section links follow the same contract.
        QVERIFY(follow(word + QStringLiteral("#Missing_owner")));
        QCOMPARE(window.loadSerial_, serial);
        QCOMPARE(window.api_->language(), QStringLiteral("Ancient Greek"));
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        const int historyCount = window.learning_.history().size();
        QVERIFY(follow(modernOnly + QStringLiteral("#Ancient_Greek")));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Ancient Greek"), 30000);
        QVERIFY(window.currentEntry_.isEmpty());
        QVERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
        QCOMPARE(window.search_->text(), modernOnly);
        QTRY_VERIFY(window.search_->hasFocus()); // Missing destinations keep search recovery available.
        QCOMPARE(window.learning_.history().size(), historyCount);
    }

    void ordinaryLinksFallBackOnlyToExactSameEditionUnclassified() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-unclassified-links-XXXXXX"));
        QVERIFY(directory.isValid());
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(),
            {QStringLiteral("source"), QStringLiteral("Shared")}, QByteArrayLiteral("el"), QByteArrayLiteral("Greek")));
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(),
            {QStringLiteral("fallback"), QStringLiteral("Shared")}, QByteArrayLiteral("und"), QByteArrayLiteral("Unclassified"), true));
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(),
            {QStringLiteral("foreign-only")}, QByteArrayLiteral("fr"), QByteArrayLiteral("French"), true));
        const QString root = directory.path() + QStringLiteral("/library");
        QFile edition(root + QStringLiteral("/.desktop-edition"));
        QVERIFY(edition.open(QIODevice::WriteOnly));
        const QByteArray editionBytes = QByteArrayLiteral("enwiktionary-20261001\n");
        QCOMPARE(edition.write(editionBytes), qint64(editionBytes.size()));
        edition.close();
        QSettings().setValue(QStringLiteral("reader/language"), QStringLiteral("Greek"));
        MainWindow window(root, QStringLiteral("source")); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        const QString originRoot = window.originRoot_, originEdition = window.originEdition_;
        const QString sourceKey = window.savedWord(window.currentEntry_).key;
        const auto follow = [&](const QString &target) {
            QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(title(window))).object();
            QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
            QJsonArray spans = entry.value(QStringLiteral("preamble_spans")).toArray();
            spans.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), QStringLiteral("Follow installed target")}, {QStringLiteral("target"), target}});
            entry.insert(QStringLiteral("preamble_spans"), spans);
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson(), false);
            return clickAnchor(window.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target)));
        };
        // The current owner's case retry wins over an equally named fallback record.
        const unsigned initialSerial = window.loadSerial_;
        QVERIFY(follow(QStringLiteral("shared")));
        QCOMPARE(window.loadSerial_, initialSerial);
        QCOMPARE(title(window), QStringLiteral("Shared"));
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QVERIFY(window.openWord(QStringLiteral("source")));
        QVERIFY(follow(QStringLiteral("fallback#Etymology")));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QCOMPARE(title(window), QStringLiteral("fallback"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A river animal.")));
        QCOMPARE(window.originRoot_, originRoot); QCOMPARE(window.originEdition_, originEdition);
        QCOMPARE(window.language_->currentText(), QStringLiteral("Unclassified"));
        QTRY_VERIFY(window.reading_->hasFocus());
        const int section = window.sections_->findText(QStringLiteral("Etymology"));
        QVERIFY(section >= 0);
        QVERIFY(!window.collapsedSections_.contains(window.sections_->itemData(section).toInt()));
        QVERIFY(window.savedWord(window.currentEntry_).key != sourceKey);
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QCOMPARE(title(window), QStringLiteral("source"));
        QCOMPARE(window.savedWord(window.currentEntry_).key, sourceKey);
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QCOMPARE(title(window), QStringLiteral("fallback"));
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QCOMPARE(title(window), QStringLiteral("source"));

        // A default search, explicit current-owner fragment, and another installed
        // language must not borrow an Unclassified or arbitrary-language target.
        unsigned serial = window.loadSerial_;
        QVERIFY(!window.openWord(QStringLiteral("fallback")));
        QCOMPARE(window.loadSerial_, serial);
        QVERIFY(follow(QStringLiteral("fallback#Greek")));
        QCOMPARE(window.loadSerial_, serial);
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        for (const QString &target : {QStringLiteral("FALLBACK"), QStringLiteral("foreign-only"), QStringLiteral("absent")}) {
            const int visitIndex = window.visitIndex_, visitCount = window.visits_.size();
            const int historyCount = window.learning_.history().size();
            QVERIFY(follow(target));
            const QJsonObject entry = window.currentEntry_;
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
            QCOMPARE(window.currentEntry_, entry);
            QCOMPARE(window.originRoot_, originRoot); QCOMPARE(window.originEdition_, originEdition);
            QCOMPARE(window.visitIndex_, visitIndex); QCOMPARE(window.visits_.size(), visitCount);
            QCOMPARE(window.learning_.history().size(), historyCount);
            QCOMPARE(QSettings().value(QStringLiteral("reader/language")).toString(), QStringLiteral("Greek"));
            QVERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        }

        // Cancellation before publication cannot install a stale fallback owner.
        const QString body = window.reading_->toPlainText();
        QVERIFY(QMetaObject::invokeMethod(window.reading_, "anchorClicked", Qt::DirectConnection,
            Q_ARG(QUrl, QUrl(QStringLiteral("dict:fallback")))));
        QVERIFY(window.loading_);
        const auto watchers = window.findChildren<QFutureWatcherBase *>();
        QVERIFY(!watchers.isEmpty()); const QPointer<QFutureWatcherBase> pending = watchers.last();
        window.cancelOpening_->click();
        QVERIFY(!window.loading_);
        QTRY_VERIFY_WITH_TIMEOUT(!pending || pending->isFinished(), 30000);
        QCoreApplication::processEvents();
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        QCOMPARE(title(window), QStringLiteral("source"));
        QCOMPARE(window.reading_->toPlainText(), body);
        QCOMPARE(window.originRoot_, originRoot); QCOMPARE(window.originEdition_, originEdition);

        // Empty/legacy edition identity and alias-origin presentation stay excluded.
        const auto assertNoFallback = [&] {
            const unsigned before = window.loadSerial_;
            QMetaObject::invokeMethod(window.reading_, "anchorClicked", Qt::DirectConnection,
                Q_ARG(QUrl, QUrl(QStringLiteral("dict:fallback"))));
            return !window.loading_ && window.loadSerial_ == before && window.api_->language() == QStringLiteral("Greek");
        };
        window.currentEntry_.insert(QStringLiteral("redirect"), QJsonObject{{QStringLiteral("followed"), true}});
        QVERIFY(assertNoFallback());
        window.currentEntry_.remove(QStringLiteral("redirect"));
        window.currentEntry_.insert(QStringLiteral("kind"), QStringLiteral("alias"));
        QVERIFY(assertNoFallback());
        window.currentEntry_.insert(QStringLiteral("kind"), QStringLiteral("language"));
        window.originEdition_.clear();
        QVERIFY(assertNoFallback());
    }

    void keyboardBackRestoresReaderLinkContext() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-keyboard-history-XXXXXX"));
        QVERIFY(directory.isValid());
        // A persistent native DPR2 fixture: three distinct ordinary links in the
        // preamble survive the real lookup performed when Back rebuilds HTML.
        const auto u32 = [](QByteArray &out, quint32 value) {
            for (int shift = 0; shift < 32; shift += 8) out.append(char(value >> shift));
        };
        const auto string = [&](QByteArray &out, const QByteArray &value) {
            u32(out, quint32(value.size())); out += value;
        };
        QByteArray presentation = QByteArrayLiteral("DPR2");
        u32(presentation, 0); // display title
        u32(presentation, 0); // sections
        u32(presentation, 3); // preamble spans
        for (const QByteArray &target : {QByteArray("same"), QByteArray("fallback"), QByteArray("neighbor")}) {
            presentation += QByteArray::fromHex("010000"); // link, normal, no flags
            string(presentation, target); string(presentation, target);
            for (int field = 0; field < 4; ++field) string(presentation, {});
        }
        for (int count = 0; count < 4; ++count) u32(presentation, 0); // layout, refs, media
        const auto install = [&](const QByteArray &code, const QByteArray &owner, const QStringList &titles) {
            QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(1) + code + '\0' + owner + '\0';
            for (const QString &word : titles) {
                bytes += word.toUtf8() + '\0';
                quint64 length = quint64(presentation.size());
                do { const auto byte = static_cast<unsigned char>(length & 127); length >>= 7;
                    bytes += char(byte | (length ? 128 : 0)); } while (length);
                bytes += presentation;
            }
            QFile source(directory.path() + QStringLiteral("/history-") + QString::fromUtf8(code) + QStringLiteral(".wikblb"));
            if (!source.open(QIODevice::WriteOnly) || source.write(bytes) != bytes.size()) return false;
            source.close(); std::atomic_bool cancelled = false;
            auto prepared = LibraryStorage::prepareImport(directory.path() + QStringLiteral("/library"), source.fileName(), {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(directory.path() + QStringLiteral("/library"), *prepared);
            return true;
        };
        QVERIFY(install("el", "Greek", {QStringLiteral("same"), QStringLiteral("source")}));
        QVERIFY(install("und", "Unclassified", {QStringLiteral("fallback"), QStringLiteral("neighbor")}));
        const QString root = directory.path() + QStringLiteral("/library");
        QFile edition(root + QStringLiteral("/.desktop-edition")); QVERIFY(edition.open(QIODevice::WriteOnly));
        QCOMPARE(edition.write("enwiktionary-20261001\n"), qint64(22)); edition.close();
        QSettings().setValue(QStringLiteral("reader/language"), QStringLiteral("Greek"));
        MainWindow window(root, QStringLiteral("source")); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        const auto key = [&](Qt::Key value, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            QWidget *focused = QApplication::focusWidget();
            if (!focused || !window.isAncestorOf(focused)) return false;
            QTest::keyClick(focused, value, modifiers); return true;
        };
        const auto href = [&] { return window.reading_->textCursor().charFormat().anchorHref(); };
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        // Select the second anchor by actual Tab traversal, not cursor injection.
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:same"));
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:fallback"));
        const int position = window.reading_->textCursor().position();
        const int anchor = window.reading_->textCursor().anchor();
        const int scroll = window.reading_->verticalScrollBar()->value();
        QVERIFY(key(Qt::Key_Return));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("fallback"));
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        QTRY_VERIFY(window.reading_->hasFocus());
        QCOMPARE(window.reading_->textCursor().position(), position);
        QCOMPARE(window.reading_->textCursor().anchor(), anchor);
        QCOMPARE(window.reading_->verticalScrollBar()->value(), scroll);
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:neighbor"));
        QVERIFY(key(Qt::Key_Return));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("neighbor"));
        // Same-owner history uses the same public cursor reconstruction path.
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        QVERIFY(key(Qt::Key_Backtab, Qt::ShiftModifier));
        QVERIFY(key(Qt::Key_Backtab, Qt::ShiftModifier)); QTRY_COMPARE(href(), QStringLiteral("dict:same"));
        QVERIFY(key(Qt::Key_Return)); QTRY_COMPARE(title(window), QStringLiteral("same"));
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier)); QTRY_COMPARE(title(window), QStringLiteral("source"));
        QTRY_VERIFY(window.reading_->hasFocus()); QTRY_COMPARE(href(), QStringLiteral("dict:same"));
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:fallback"));
        // Revisiting a search-origin visit must not steal focus into the reader.
        window.search_->setText(QStringLiteral("same")); window.search_->setFocus();
        QTRY_VERIFY(window.search_->hasFocus());
        QVERIFY(key(Qt::Key_Return)); QTRY_COMPARE(title(window), QStringLiteral("same"));
        for (int step = 0; step < 64 && !window.reading_->hasFocus(); ++step)
            QVERIFY(key(Qt::Key_Tab));
        QTRY_VERIFY(window.reading_->hasFocus());
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier)); QTRY_COMPARE(title(window), QStringLiteral("source"));
        QTRY_VERIFY(window.search_->hasFocus());
    }

    void exactSearchPreservesExplicitSelection_data() {
        QTest::addColumn<QString>("action");
        QTest::addColumn<bool>("typeSecond");
        QTest::addColumn<int>("expectedRow");
        QTest::newRow("typed-exact") << QStringLiteral("typed") << true << 1;
        QTest::newRow("arrow-down-unchanged-row-zero") << QStringLiteral("down") << true << 0;
        QTest::newRow("arrow-up-transfer-last-row") << QStringLiteral("up") << false << 1;
        QTest::newRow("list-down") << QStringLiteral("list-down") << false << 1;
        QTest::newRow("list-up") << QStringLiteral("list-up") << true << 0;
        QTest::newRow("home") << QStringLiteral("home") << true << 0;
        QTest::newRow("end") << QStringLiteral("end") << false << 1;
        QTest::newRow("page-up") << QStringLiteral("page-up") << true << 0;
        QTest::newRow("page-down") << QStringLiteral("page-down") << false << 1;
        QTest::newRow("mouse-alternate") << QStringLiteral("mouse") << false << 1;
        QTest::newRow("list-enter-alternate") << QStringLiteral("list-enter") << false << 1;
    }

    void exactSearchPreservesExplicitSelection() {
        QFETCH(QString, action);
        QFETCH(bool, typeSecond);
        QFETCH(int, expectedRow);
        QTemporaryDir directory(QStringLiteral(".tmp/ui-exact-selection-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString path = QDir(directory.path()).absolutePath();
        QVERIFY(prepareCaseTitleFixture(fixture_, path, {QStringLiteral("Apple"), QStringLiteral("apple")}));
        MainWindow window(path + QStringLiteral("/library"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.search_->setText(QStringLiteral("app"));
        QTRY_COMPARE(window.resultsQuery_, QStringLiteral("app"));
        QTRY_COMPARE(window.results_->count(), 2);
        const QString first = window.results_->item(0)->data(Qt::UserRole).toString();
        const QString second = window.results_->item(1)->data(Qt::UserRole).toString();
        QVERIFY(first != second);
        const QString typed = typeSecond ? second : first;
        const QString expected = expectedRow == 0 ? first : second;
        window.search_->setText(typed);
        QTRY_COMPARE(window.resultsQuery_, typed);
        QTRY_COMPARE(window.results_->count(), 2);
        window.search_->setFocus();
        if (action == QStringLiteral("mouse")) {
            window.results_->scrollToItem(window.results_->item(1));
            QTest::mouseClick(window.results_->viewport(), Qt::LeftButton, Qt::NoModifier,
                window.results_->visualItemRect(window.results_->item(1)).center());
        } else {
            if (action != QStringLiteral("typed")) {
                QTest::keyClick(window.search_, action == QStringLiteral("up") ? Qt::Key_Up : Qt::Key_Down);
                if (action == QStringLiteral("list-down") || action == QStringLiteral("list-enter"))
                    QTest::keyClick(window.results_, Qt::Key_Down);
                if (action == QStringLiteral("list-up") || action == QStringLiteral("home") || action == QStringLiteral("page-up"))
                    QTest::keyClick(window.results_, Qt::Key_End);
                if (action == QStringLiteral("list-up")) QTest::keyClick(window.results_, Qt::Key_Up);
                if (action == QStringLiteral("home")) QTest::keyClick(window.results_, Qt::Key_Home);
                if (action == QStringLiteral("end")) QTest::keyClick(window.results_, Qt::Key_End);
                if (action == QStringLiteral("page-up")) QTest::keyClick(window.results_, Qt::Key_PageUp);
                if (action == QStringLiteral("page-down")) QTest::keyClick(window.results_, Qt::Key_PageDown);
                QCOMPARE(window.results_->currentRow(), expectedRow);
                if (action != QStringLiteral("list-enter"))
                    QTest::keyClick(window.results_, Qt::Key_Escape);
            }
            QTest::keyClick(action == QStringLiteral("list-enter") ? static_cast<QWidget *>(window.results_) :
                static_cast<QWidget *>(window.search_), Qt::Key_Return);
        }
        QTRY_COMPARE(title(window), expected);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));

        // A new query resets an earlier explicit choice without changing the row ordering.
        const QString next = expected == first ? second : first;
        window.search_->setText(next);
        QTRY_COMPARE(window.resultsQuery_, next);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), next);
    }

    void exactSearchFindsTitleBeyondFirstSuggestionPage() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-exact-page-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString path = QDir(directory.path()).absolutePath();
        QStringList variants;
        for (unsigned bits = 0; bits < 96; ++bits) {
            QString word = QStringLiteral("caseword");
            for (int i = 0; i < word.size(); ++i)
                if (bits & (1u << i)) word[i] = word[i].toUpper();
            variants.append(word);
        }
        QVERIFY(prepareCaseTitleFixture(fixture_, path, variants));
        MainWindow window(path + QStringLiteral("/library"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QCOMPARE(window.searchTitles_.size(), 96);
        const QString exact = window.searchTitles_.last();
        window.search_->setText(exact);
        QTRY_COMPARE(window.resultsQuery_, exact);
        QTRY_COMPARE(window.results_->count(), 80);
        QVERIFY(window.moreResults_->isEnabled());
        for (int i = 0; i < window.results_->count(); ++i)
            QVERIFY(window.results_->item(i)->data(Qt::UserRole).toString() != exact);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), exact);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
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
        QTest::keyClicks(window.search_, "<b>missing</b>");
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_VERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
        QCOMPARE(title(window), QStringLiteral("dog"));
        QCOMPARE(window.results_->count(), 0);
        const QString literal = QStringLiteral("No exact entry for “<b>missing</b>”. Try a suggestion or another collection.");
        QCOMPARE(window.resultStatus_->text(), literal);
        // Capture the ordinary missing-word state before the isolated label-render oracle.
        window.resize(780, 480);
        QCoreApplication::processEvents();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-no-exact-match.png")));
        // The narrow sidebar may scroll, but the complete wrapped feedback must remain reachable.
        window.resize(580, 480);
        QCoreApplication::processEvents();
        auto *sidebar = window.findChild<QScrollArea *>(QStringLiteral("readerSidebarScroll"));
        QVERIFY(sidebar);
        QVERIFY(window.resultStatus_->wordWrap());
        QVERIFY(window.resultStatus_->heightForWidth(window.resultStatus_->width()) > 0);
        QVERIFY(window.resultStatus_->height() >= window.resultStatus_->heightForWidth(window.resultStatus_->width()));
        sidebar->ensureWidgetVisible(window.resultStatus_);
        QCoreApplication::processEvents();
        QVERIFY(sidebar->viewport()->rect().contains(QRect(window.resultStatus_->mapTo(sidebar->viewport(), QPoint()), window.resultStatus_->size())));
        QCOMPARE(sidebar->horizontalScrollBar()->maximum(), 0);
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-no-exact-match-narrow.png")));
        window.resultStatus_->setFixedSize(440, 120);
        QLabel plain(window.resultStatus_->parentWidget());
        QLabel rich(window.resultStatus_->parentWidget());
        for (QLabel *reference : {&plain, &rich}) {
            reference->setFont(window.resultStatus_->font());
            reference->setPalette(window.resultStatus_->palette());
            reference->setFixedSize(window.resultStatus_->size());
            reference->setWordWrap(window.resultStatus_->wordWrap());
            reference->setAlignment(window.resultStatus_->alignment());
            reference->setMargin(window.resultStatus_->margin());
            reference->setIndent(window.resultStatus_->indent());
            reference->setText(literal);
        }
        plain.setTextFormat(Qt::PlainText);
        rich.setTextFormat(Qt::RichText);
        const auto rendered = [](QLabel &label) {
            QImage image(label.size(), QImage::Format_ARGB32_Premultiplied);
            image.fill(Qt::transparent);
            label.render(&image);
            return image;
        };
        const QImage plainImage = rendered(plain);
        const QImage richImage = rendered(rich);
        QVERIFY(plainImage != richImage);
        QCOMPARE(rendered(*window.resultStatus_), plainImage);

        auto *accessible = QAccessible::queryAccessibleInterface(window.resultStatus_);
        QVERIFY(accessible);
        QCOMPARE(accessible->text(QAccessible::Name), literal);
        QCOMPARE(accessible->text(QAccessible::Description), QStringLiteral("Search status"));
        QTest::keyClick(window.search_, Qt::Key_A, Qt::ControlModifier);
        QTest::keyClicks(window.search_, "cat");
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.resultStatus_->text() != literal);
        QCOMPARE(accessible->text(QAccessible::Name), window.resultStatus_->text());
    }

    void keyboardTraversalUsesActualFocusAndKeepsBackReachable() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.search_->setText(QStringLiteral("dog"));
        QTRY_COMPARE(window.resultsQuery_, QStringLiteral("dog"));
        QTRY_VERIFY(window.results_->count() > 0);
        auto dogResultRow = [&window] {
            for (int row = 0; row < window.results_->count(); ++row)
                if (window.results_->item(row)->data(Qt::UserRole).toString() == QStringLiteral("dog"))
                    return row;
            return -1;
        };
        QTRY_VERIFY(dogResultRow() >= 0);
        const int dogRow = dogResultRow();

        // Send Qt test events only to the actual focus owner. This does not prove
        // physical keyboard delivery or a visible focus indicator.
        auto focusedKey = [&window](Qt::Key key, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            QWidget *owner = QApplication::focusWidget();
            if (!owner || !window.isAncestorOf(owner) || !owner->isEnabled())
                return false;
            QTest::keyClick(owner, key, modifiers);
            QCoreApplication::processEvents();
            return true;
        };
        window.search_->setFocus(Qt::TabFocusReason);
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        QVERIFY(focusedKey(Qt::Key_Tab));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QVERIFY(focusedKey(Qt::Key_Backtab, Qt::ShiftModifier));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));

        QVERIFY(focusedKey(Qt::Key_Down));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QCOMPARE(window.results_->currentRow(), 0);
        QVERIFY(focusedKey(Qt::Key_Escape));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        QVERIFY(focusedKey(Qt::Key_Down));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QCOMPARE(window.results_->currentRow(), 0);
        for (int row = 0; row < dogRow; ++row) {
            QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
            QVERIFY(focusedKey(Qt::Key_Down));
            QCOMPARE(window.results_->currentRow(), row + 1);
        }
        QCOMPARE(window.results_->currentItem()->data(Qt::UserRole).toString(), QStringLiteral("dog"));
        QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QVERIFY(focusedKey(Qt::Key_Return));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QTRY_VERIFY(window.back_->isEnabled());

        // Do not assume a platform-specific number of intermediate tab stops.
        window.search_->setFocus(Qt::TabFocusReason);
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        for (int step = 0; step < 64 && QApplication::focusWidget() != window.back_; ++step)
            QVERIFY(focusedKey(Qt::Key_Tab));
        QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.back_));
        QVERIFY(window.back_->isEnabled());
        QVERIFY(focusedKey(Qt::Key_Space));
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTRY_VERIFY(window.forward_->isEnabled());
        QTRY_VERIFY(QApplication::focusWidget() &&
            window.isAncestorOf(QApplication::focusWidget()) &&
            QApplication::focusWidget()->isEnabled());
    }

    void backAndForwardPreserveSelectedAliasIdentity() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-alias-back-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        const auto progress = [](const QString &, qint64, qint64) {};
        for (const QString &file : {
                QStringLiteral("languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                QStringLiteral("alias-cases/aliases.wikblb")}) {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QChar('/') + file, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *prepared);
        }
        MainWindow window(root); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QVERIFY(window.openWord(QStringLiteral("Loop A")));
        QCOMPARE(title(window), QStringLiteral("Loop B"));
        QVERIFY(window.openWord(QStringLiteral("dog")));
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("Loop B"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("kind")).toString(), QStringLiteral("alias"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("source_title")).toString(), QStringLiteral("Loop A"));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));

        QVERIFY(window.openWord(QStringLiteral("cat")));
        const auto ordinaryVisits = window.visits_.size();
        QVERIFY(window.openWord(QStringLiteral("Cats")));
        QCOMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.visits_.size(), ordinaryVisits + 1);
        QVERIFY(window.openWord(QStringLiteral("Cats")));
        QCOMPARE(window.visits_.size(), ordinaryVisits + 1);
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.currentEntry_.value(QStringLiteral("redirect")).toObject().isEmpty());
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_COMPARE(window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("source_title")).toString(), QStringLiteral("Cats"));
        QCOMPARE(title(window), QStringLiteral("cat"));
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

    void compiledHeadingAnchorsSelectSectionAndStandaloneDestinations() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        const auto text = [](const QString &value) { return QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        const auto section = [&](const QString &anchor, const QString &body) { return QJsonObject{
            {QStringLiteral("level"), 3}, {QStringLiteral("title"), QStringLiteral("Noun")}, {QStringLiteral("anchor"), anchor},
            {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{text(body)}}}}}}; };
        QJsonObject standalone{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4},
            {QStringLiteral("anchor"), QStringLiteral("Noun_4")}, {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Noun"))}}};
        QJsonObject owner = section(QStringLiteral("Noun_3"), QStringLiteral("THIRD SECTION BODY"));
        QJsonArray blocks = owner.value(QStringLiteral("blocks")).toArray();
        blocks.append(standalone);
        blocks.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("STANDALONE HEADING BODY"))}}});
        owner.insert(QStringLiteral("blocks"), blocks);
        QJsonObject second = section(QStringLiteral("Noun_2"), QStringLiteral("SECOND SECTION BODY"));
        QJsonArray secondBlocks = second.value(QStringLiteral("blocks")).toArray();
        secondBlocks.prepend(QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 3},
            {QStringLiteral("anchor"), QStringLiteral("Noun_2")}, {QStringLiteral("spans"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Noun")},
                {QStringLiteral("target"), QStringLiteral("cat")}}}}});
        second.insert(QStringLiteral("blocks"), secondBlocks);
        entry.insert(QStringLiteral("sections"), QJsonArray{section(QStringLiteral("Noun"), QStringLiteral("FIRST SECTION BODY")), second, owner});
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Second noun")}, {QStringLiteral("target"), QStringLiteral("#Noun_2")}}});
        const auto publish = [&](const std::optional<QString> &fragment = std::nullopt) {
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson(), true, fragment);
        };
        publish();
        QCOMPARE(window.sections_->count(), 5); // Rich first companion shares its section row; standalone heading adds one.
        window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23Noun_2")));
        QVERIFY(window.collapsedSections_.contains(0));
        QVERIFY(!window.collapsedSections_.contains(1));
        QVERIFY(window.collapsedSections_.contains(2));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("SECOND SECTION BODY")));

        // openWord publishes an explicit cross-entry fragment through this boundary.
        publish(QStringLiteral("Noun_4"));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-2-1")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("STANDALONE HEADING BODY")));
        QCOMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.sections_->itemData(4).toInt(), 2);
        QCOMPARE(window.sections_->itemData(4, Qt::UserRole + 1).toInt(), 1);
        window.collapsedSections_.insert(2); window.refreshReading();
        QVERIFY(QMetaObject::invokeMethod(window.sections_, "activated", Qt::DirectConnection, Q_ARG(int, 4)));
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-2-1")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("STANDALONE HEADING BODY")));

        entry.insert(QStringLiteral("redirect"), QJsonObject{{QStringLiteral("source_title"), QStringLiteral("Alias cat")},
            {QStringLiteral("target_title"), QStringLiteral("cat")}, {QStringLiteral("fragment"), QStringLiteral("Noun_2")},
            {QStringLiteral("followed"), true}});
        publish(); // The same compiled destination is inherited from an alias.
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("SECOND SECTION BODY")));
        publish(QStringLiteral("Noun_4")); // An explicit fragment overrides the alias destination.
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("STANDALONE HEADING BODY")));

        entry.remove(QStringLiteral("redirect"));
        QJsonArray anchored = entry.value(QStringLiteral("sections")).toArray();
        QJsonObject spaced = anchored[0].toObject(); spaced.insert(QStringLiteral("anchor"), QStringLiteral("Usage_notes"));
        QJsonObject reference = anchored[1].toObject(); reference.insert(QStringLiteral("anchor"), QStringLiteral("reference-1"));
        anchored[0] = spaced; anchored[1] = reference; entry.insert(QStringLiteral("sections"), anchored);
        publish(); window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        window.jumpToFragment(QStringLiteral("Usage notes"));
        QVERIFY(!window.collapsedSections_.contains(0));
        window.jumpToFragment(QStringLiteral("reference-1"));
        QVERIFY(!window.collapsedSections_.contains(1)); // Authored identity precedes synthetic reference fallback.
        QJsonArray legacy = entry.value(QStringLiteral("sections")).toArray();
        for (qsizetype i = 0; i < legacy.size(); ++i) {
            QJsonObject value = legacy[i].toObject(); value.remove(QStringLiteral("anchor"));
            value.insert(QStringLiteral("blocks"), QJsonArray{}); legacy[i] = value;
        }
        entry.insert(QStringLiteral("sections"), legacy);
        publish(); window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        window.jumpToFragment(QStringLiteral("Noun"));
        QCOMPARE(window.collapsedSections_, QSet<int>({0, 1, 2})); // Ambiguous legacy labels do not invent an identity.
        QJsonObject unique = legacy[0].toObject(); unique.insert(QStringLiteral("title"), QStringLiteral("Usage notes"));
        legacy[0] = unique; entry.insert(QStringLiteral("sections"), legacy);
        publish(); window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        window.jumpToFragment(QStringLiteral("Usage_notes"));
        QVERIFY(!window.collapsedSections_.contains(0));

        // Primary and fallback IDs share the producer's page-order collision namespace.
        const QString umlaut(QChar(0x00e4));
        QJsonObject unicode = section(umlaut, QStringLiteral("UNICODE HEADING BODY"));
        unicode.insert(QStringLiteral("title"), umlaut);
        unicode.insert(QStringLiteral("anchor_fallback"), QStringLiteral(".C3.A4"));
        QJsonObject literal = section(QStringLiteral(".C3.A4_2"), QStringLiteral("LITERAL DOT HEADING BODY"));
        literal.insert(QStringLiteral("title"), QStringLiteral(".C3.A4"));
        QJsonObject repeated{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4},
            {QStringLiteral("anchor"), umlaut + QStringLiteral("_2")},
            {QStringLiteral("anchor_fallback"), QStringLiteral(".C3.A4_3")},
            {QStringLiteral("spans"), QJsonArray{text(umlaut)}}};
        QJsonObject blockOwner = section(QStringLiteral("Owner"), QStringLiteral("OWNER BODY"));
        blockOwner.insert(QStringLiteral("title"), QStringLiteral("Owner"));
        blockOwner.insert(QStringLiteral("blocks"), QJsonArray{repeated, QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("REPEATED UNICODE BLOCK BODY"))}}}});
        entry.insert(QStringLiteral("sections"), QJsonArray{unicode, literal, blockOwner});
        publish();
        const auto expectOwner = [&](const QString &fragment, int expected) {
            window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
            window.jumpToFragment(fragment);
            QSet<int> folded{0, 1, 2}; folded.remove(expected);
            QCOMPARE(window.collapsedSections_, folded);
        };
        expectOwner(umlaut, 0);
        expectOwner(QStringLiteral(".C3.A4"), 0); // Exact retained fallback, never reader unescaping.
        expectOwner(QStringLiteral(".C3.A4_2"), 1); // Literal dot spelling owns the collision suffix.
        expectOwner(umlaut + QStringLiteral("_2"), 2);
        expectOwner(QStringLiteral(".C3.A4_3"), 2); // Standalone Block.anchor_fallback.
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-2-0")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("REPEATED UNICODE BLOCK BODY")));
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

    void emptyReferenceLeafUsesMetadataHeadingAndLinks() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        const QJsonObject entry = qichwaReferenceShape();
        QVERIFY(!entry.isEmpty());
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        const QString html = window.entryHtml(entry);
        const QString plain = window.reading_->toPlainText();
        QCOMPARE(plain.count(QStringLiteral("References")), 1);
        QCOMPARE(plain.count(QStringLiteral("Reference one proof.")), 1);
        QCOMPARE(plain.count(QStringLiteral("Reference two proof.")), 1);
        QVERIFY(!html.contains(QStringLiteral("href='section:7'"))); // No empty fold control.
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-7")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("reference-1")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("reference-2")));
        int sectionPosition = -1;
        for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next()) {
            if (block.charFormat().anchorNames().contains(QStringLiteral("section-7"))) sectionPosition = block.position();
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const QTextFragment fragment = it.fragment();
                if (fragment.isValid() && fragment.charFormat().anchorNames().contains(QStringLiteral("section-7")))
                    sectionPosition = fragment.position();
            }
        }
        const QTextCursor lastFurther = window.reading_->document()->find(QStringLiteral("Last further-reading marker."));
        const QTextCursor firstReference = window.reading_->document()->find(QStringLiteral("Reference one proof."));
        QVERIFY(!lastFurther.isNull() && !firstReference.isNull());
        QVERIFY(sectionPosition >= lastFurther.selectionEnd());
        QVERIFY(sectionPosition <= firstReference.selectionStart());

        const QJsonObject example = entry.value(QStringLiteral("sections")).toArray()[4].toObject()
            .value(QStringLiteral("blocks")).toArray().first().toObject();
        const QString exampleHtml = window.blockHtml(example);
        QCOMPARE(exampleHtml.count(QStringLiteral("<blockquote>")), 1);
        QCOMPARE(exampleHtml.count(QStringLiteral("<br>")), 1); // Keep only the authored translation break.
        QVERIFY(exampleHtml.indexOf(QStringLiteral("We are speaking ")) > exampleHtml.indexOf(QStringLiteral("<br>")));
        QVERIFY(exampleHtml.indexOf(QStringLiteral("We are speaking ")) < exampleHtml.indexOf(QStringLiteral("</blockquote>")));
        QVERIFY(exampleHtml.contains(QStringLiteral("<i><b>qhichwa</b></i>")));
        QVERIFY(exampleHtml.contains(QStringLiteral("dict:%C3%B1uqanchik%23Quechua")));

        // The old empty leaf could have been saved as collapsed. Metadata stays
        // available, and both heading/menu navigation and numbered links reach it.
        window.collapsedSections_.insert(7);
        window.refreshReading();
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Reference two proof.")));
        const int row = window.sections_->findData(7);
        QVERIFY(row >= 0);
        QVERIFY(QMetaObject::invokeMethod(window.sections_, "activated", Qt::DirectConnection, Q_ARG(int, row)));
        QVERIFY(!window.collapsedSections_.contains(7));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Reference one proof.")));
        window.collapsedSections_.insert(7);
        window.refreshReading();
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23References")));
        QVERIFY(!window.collapsedSections_.contains(7));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Reference one proof.")));
        window.collapsedSections_.insert(7);
        window.refreshReading();
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23reference-2")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Reference two proof.")));
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-reference-placeholder-footer.png")));
    }

    void detailTrailingBreaksPreserveSemanticWhitespace_data() {
        QTest::addColumn<QString>("kind");
        QTest::addColumn<QJsonObject>("tail");
        QTest::addColumn<int>("breaks");
        const QJsonObject plain{{QStringLiteral("kind"), QStringLiteral("line_break")},
            {QStringLiteral("text"), QStringLiteral("\n")}};
        QTest::newRow("example-padding") << QStringLiteral("example") << plain << 1;
        QTest::newRow("quotation-padding") << QStringLiteral("quotation") << plain << 1;
        QTest::newRow("paragraph-boundary") << QStringLiteral("paragraph") << plain << 2;
        QTest::newRow("preformatted-boundary") << QStringLiteral("preformatted") << plain << 2;
        const auto protectedTail = [&](const char *name, const QString &key, const QJsonValue &value) {
            QJsonObject tail = plain;
            tail.insert(key, value);
            QTest::newRow(name) << QStringLiteral("quotation") << tail << 2;
        };
        QJsonObject annotated = plain;
        annotated.insert(QStringLiteral("classes"), QStringLiteral("h-usage-example"));
        QTest::newRow("usage-example-padding") << QStringLiteral("example") << annotated << 1;
        protectedTail("unknown-class", QStringLiteral("classes"), QStringLiteral("authored-whitespace"));
        protectedTail("painted", QStringLiteral("background"), QStringLiteral("#ff0000"));
        protectedTail("literal-code", QStringLiteral("code"), true);
        protectedTail("styled", QStringLiteral("italic"), true);
        protectedTail("trail", QStringLiteral("trail"), QStringLiteral("Retained tail"));
        protectedTail("target", QStringLiteral("target"), QStringLiteral("#References"));
        protectedTail("nonbreaking-space", QStringLiteral("text"), QStringLiteral("\u00a0"));
        QJsonObject literal{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("text"), QStringLiteral(" \n")}};
        QTest::newRow("literal-text-whitespace") << QStringLiteral("example") << literal << 1;
    }

    void detailTrailingBreaksPreserveSemanticWhitespace() {
        QFETCH(QString, kind);
        QFETCH(QJsonObject, tail);
        QFETCH(int, breaks);
        MainWindow window(QString{});
        const QJsonObject source{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Source")}, {QStringLiteral("target"), QStringLiteral("source#Quechua")},
            {QStringLiteral("italic"), true}};
        const QJsonObject internal{{QStringLiteral("kind"), QStringLiteral("line_break")}};
        const QJsonObject translation{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("text"), QStringLiteral("Translation")}};
        const QJsonObject block{{QStringLiteral("kind"), kind},
            {QStringLiteral("spans"), QJsonArray{source, internal, translation, tail}}};
        const QByteArray stored = QJsonDocument(block).toJson(QJsonDocument::Compact);
        const QString html = window.blockHtml(block);
        QCOMPARE(html.count(QStringLiteral("<br>")), breaks);
        QVERIFY(html.contains(QStringLiteral("dict:source%23Quechua")));
        QVERIFY(html.contains(QStringLiteral("<i><a href='dict:source%23Quechua'>Source</a></i>")));
        QVERIFY(html.indexOf(QStringLiteral("<br>")) < html.indexOf(QStringLiteral("Translation")));
        if (tail.value(QStringLiteral("kind")) == QStringLiteral("text"))
            QVERIFY(html.contains(QStringLiteral("Translation \n")));
        if (!tail.value(QStringLiteral("trail")).toString().isEmpty())
            QVERIFY(html.contains(QStringLiteral("Retained tail")));
        QCOMPARE(QJsonDocument(block).toJson(QJsonDocument::Compact), stored);

        // A poem elsewhere in the block protects even an ordinary terminal break.
        QJsonObject poemSource = source;
        poemSource.insert(QStringLiteral("classes"), QStringLiteral("wikidict-poem"));
        const QJsonArray poemSpans{poemSource, internal, translation, internal};
        const QJsonObject poem{{QStringLiteral("kind"), QStringLiteral("quotation")},
            {QStringLiteral("spans"), poemSpans}};
        QCOMPARE(window.blockHtml(poem), QStringLiteral("<blockquote>%1</blockquote>").arg(window.spansHtml(poemSpans)));
    }

    void authoredReferenceSectionsAreNotDiscarded_data() {
        QTest::addColumn<QString>("control");
        QTest::newRow("nonempty") << QStringLiteral("nonempty");
        QTest::newRow("parent") << QStringLiteral("parent");
        QTest::newRow("ambiguous") << QStringLiteral("ambiguous");
        QTest::newRow("no-metadata") << QStringLiteral("no-metadata");
    }

    void authoredReferenceSectionsAreNotDiscarded() {
        QFETCH(QString, control);
        MainWindow window(QString{});
        QJsonObject entry = qichwaReferenceShape();
        QJsonArray sections = entry.value(QStringLiteral("sections")).toArray();
        QJsonObject referenceSection = sections[7].toObject();
        const QJsonObject body{{QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QStringLiteral("Authored reference section content.")}}}}};
        if (control == QStringLiteral("nonempty")) {
            referenceSection.insert(QStringLiteral("blocks"), QJsonArray{body});
            sections[7] = referenceSection;
        } else if (control == QStringLiteral("parent")) {
            sections.insert(8, QJsonObject{{QStringLiteral("level"), 4}, {QStringLiteral("title"), QStringLiteral("Source details")},
                {QStringLiteral("blocks"), QJsonArray{body}}});
        } else if (control == QStringLiteral("ambiguous")) {
            referenceSection.insert(QStringLiteral("anchor"), QStringLiteral("References_2"));
            sections.append(referenceSection);
        } else {
            QCOMPARE(control, QStringLiteral("no-metadata"));
            entry.insert(QStringLiteral("references"), QJsonArray{});
        }
        entry.insert(QStringLiteral("sections"), sections);
        const QString html = window.entryHtml(entry);
        QVERIFY(html.contains(QStringLiteral("href='section:7'")));
        QVERIFY(html.indexOf(QStringLiteral("name='section-7'")) < html.indexOf(QStringLiteral("Last further-reading marker.")));
        QTextDocument document;
        document.setHtml(html);
        const QString plain = document.toPlainText();
        QCOMPARE(plain.count(QStringLiteral("References")), control == QStringLiteral("ambiguous") ? 3
            : control == QStringLiteral("no-metadata") ? 1 : 2);
        if (control == QStringLiteral("nonempty") || control == QStringLiteral("parent"))
            QVERIFY(plain.contains(QStringLiteral("Authored reference section content.")));
        if (control == QStringLiteral("no-metadata")) {
            QVERIFY(!hasAnchor(&document, QStringLiteral("reference-1")));
        } else {
            QCOMPARE(plain.count(QStringLiteral("Reference one proof.")), 1);
            QCOMPARE(plain.count(QStringLiteral("Reference two proof.")), 1);
        }
    }

    void bookmarksSurviveLargeLibrariesAndSubsequentSaves() {
        QJsonArray rows;
        QVector<SavedWord> expected;
        for (int index = 0; index < 1025; ++index) {
            SavedWord word;
            word.key = QStringLiteral("saved-%1").arg(index);
            word.title = QString::fromUtf8("слово");
            word.language = QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QString::fromUtf8("معنى %1").arg(index);
            word.originRoot = QStringLiteral("/saved-fixture/%1").arg(index % 2);
            word.originEdition = index % 2 ? QStringLiteral("frwiktionary-20261001") : QStringLiteral("enwiktionary-20261001");
            word.savedAt = index + 10;
            word.lastViewed = index + 20;
            word.views = index + 1;
            expected.append(word);
            rows.append(QJsonObject{
                {QStringLiteral("key"), word.key}, {QStringLiteral("title"), word.title},
                {QStringLiteral("language"), word.language}, {QStringLiteral("kind"), word.kind},
                {QStringLiteral("clue"), word.clue}, {QStringLiteral("origin_root"), word.originRoot},
                {QStringLiteral("origin_edition"), word.originEdition},
                {QStringLiteral("saved_at"), double(word.savedAt)},
                {QStringLiteral("last_viewed"), double(word.lastViewed)}, {QStringLiteral("views"), word.views}});
        }
        QSettings storage(QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
        storage.setValue(QStringLiteral("learning/state"), QJsonDocument(QJsonObject{
            {QStringLiteral("bookmarks"), rows},
            {QStringLiteral("history"), QJsonArray{rows.at(0), rows.at(1), rows.at(2), rows.at(3)}},
            {QStringLiteral("settings"), QJsonObject{{QStringLiteral("history_limit"), 3}}}
        }).toJson(QJsonDocument::Compact));
        storage.sync();
        QCOMPARE(storage.status(), QSettings::NoError);
        const auto compareWords = [](const QVector<SavedWord> &actual, const QVector<SavedWord> &wanted) {
            QCOMPARE(actual.size(), wanted.size());
            for (qsizetype index = 0; index < wanted.size(); ++index) {
                const SavedWord &a = actual.at(index), &b = wanted.at(index);
                QCOMPARE(a.key, b.key); QCOMPARE(a.title, b.title); QCOMPARE(a.language, b.language);
                QCOMPARE(a.kind, b.kind); QCOMPARE(a.clue, b.clue);
                QCOMPARE(a.originRoot, b.originRoot); QCOMPARE(a.originEdition, b.originEdition);
                QCOMPARE(a.savedAt, b.savedAt); QCOMPARE(a.lastViewed, b.lastViewed); QCOMPARE(a.views, b.views);
            }
        };
        LearningStore store;
        QCOMPARE(store.bookmarks().size(), 1025);
        compareWords(store.bookmarks(), expected);
        QCOMPARE(store.history().size(), 3);
        SavedWord added = expected.first();
        added.key = QStringLiteral("saved-new");
        added.title = QStringLiteral("new word");
        QVERIFY(store.toggleBookmark(added));
        QCOMPARE(store.bookmarks().size(), 1026);
        expected.prepend(store.bookmarks().first()); // Keep the actual assigned savedAt timestamp.
        compareWords(store.bookmarks(), expected);
        store.record(added);
        store.setTheme(QStringLiteral("dark"));
        storage.sync();
        QCOMPARE(storage.status(), QSettings::NoError);
        LearningStore reopened;
        compareWords(reopened.bookmarks(), expected);
        QCOMPARE(reopened.history().size(), 3);
        QCOMPARE(reopened.history().first().key, added.key);
        QCOMPARE(reopened.settings().theme, QStringLiteral("dark"));
        QVERIFY(reopened.toggleBookmark(added) == false);
        expected.removeFirst();
        LearningStore afterRemoval;
        compareWords(afterRemoval.bookmarks(), expected);
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
        QCOMPARE(window.clueFor(entry), QStringLiteral("Parent ordered · Nested unordered · Nested ordered · Parent continuation · Explicit value · Following value · Alphabetic label · Roman label · Roman value · Escaped label · {{example}} [[literal]]"));
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

    void headingsKeepCompiledDepthLevelAndCompanionActions() {
        MainWindow window{QString()};
        const auto heading = [](const QString &dialect, int depth, int level = 4) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), level},
                {QStringLiteral("depth"), depth}, {QStringLiteral("list_path"), QString(depth, QChar(':'))},
                {QStringLiteral("spans"), QJsonArray{
                    QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("Se beiga ")}, {QStringLiteral("italic"), true}},
                    QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("la conchugazión ") + dialect},
                        {QStringLiteral("target"), QStringLiteral("templlar/conj.") + (dialect == QStringLiteral("benasquesa") ? QStringLiteral("BEN") : QStringLiteral("RIB"))},
                        {QStringLiteral("bold"), true}, {QStringLiteral("italic"), true}},
                    QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral(" d'este berbo.")}, {QStringLiteral("italic"), true}}}}};
        };
        // Use entryHtml so the section h2 stylesheet is present: ordinary h2 must not inherit its sans-serif family.
        QJsonArray levelBlocks;
        for (int level = 1; level <= 6; ++level)
            levelBlocks.append(heading(QStringLiteral("level%1").arg(level), 0, level));
        const QJsonObject levelsEntry{{QStringLiteral("kind"), QStringLiteral("language")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Typography controls")},
                {QStringLiteral("level"), 2}, {QStringLiteral("blocks"), levelBlocks}}}}};
        QTextDocument levelsDocument;
        QString levelsHtml = window.entryHtml(levelsEntry);
        const qsizetype bodyEnd = levelsHtml.lastIndexOf(QStringLiteral("</body>"));
        QVERIFY(bodyEnd >= 0);
        levelsHtml.insert(bodyEnd, QStringLiteral("<h3>Legacy h3 typography control</h3>"));
        levelsDocument.setHtml(levelsHtml);
        levelsDocument.setTextWidth(560);
        levelsDocument.documentLayout()->documentSize();
        const QTextCursor oldH3Style = levelsDocument.find(QStringLiteral("Legacy h3 typography control"));
        QVERIFY(!oldH3Style.isNull());
        const auto glyphSizes = [](const QTextCursor &cursor) {
            QJsonArray sizes;
            const QTextBlock block = cursor.block();
            for (const QGlyphRun &run : block.layout()->glyphRuns(cursor.selectionStart() - block.position(), cursor.selectedText().size()))
                sizes.append(run.rawFont().pixelSize());
            return sizes;
        };
        const auto glyphFamilies = [](const QTextCursor &cursor) {
            QJsonArray families;
            const QTextBlock block = cursor.block();
            for (const QGlyphRun &run : block.layout()->glyphRuns(cursor.selectionStart() - block.position(), cursor.selectedText().size())) {
                const QString family = run.rawFont().familyName();
                if (!families.contains(family)) families.append(family);
            }
            return families;
        };
        const QJsonArray legacyFamilies = glyphFamilies(oldH3Style);
        QVERIFY(!legacyFamilies.isEmpty());
        const QJsonArray legacyPixels = glyphSizes(oldH3Style);
        QVERIFY(!legacyPixels.isEmpty());
        QJsonArray computedFonts;
        for (int level = 1; level <= 6; ++level) {
            const QTextCursor cursor = levelsDocument.find(QStringLiteral("level%1").arg(level));
            QVERIFY(!cursor.isNull());
            computedFonts.append(QJsonObject{{QStringLiteral("level"), level},
                {QStringLiteral("size_adjustment"), cursor.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
                {QStringLiteral("requested_point_size"), cursor.charFormat().fontPointSize()},
                {QStringLiteral("glyph_pixel_sizes"), glyphSizes(cursor)},
                {QStringLiteral("resolved_glyph_families"), glyphFamilies(cursor)}});
        }
        qInfo().noquote() << "HEADING_FONT_METRICS" << QJsonDocument(QJsonObject{
            {QStringLiteral("legacy_h3_adjustment"), oldH3Style.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
            {QStringLiteral("legacy_h3_glyph_pixels"), legacyPixels},
            {QStringLiteral("legacy_h3_resolved_glyph_families"), legacyFamilies}, {QStringLiteral("computed_headings"), computedFonts}}).toJson(QJsonDocument::Compact);
        for (int level = 1; level <= 6; ++level) {
            const QTextCursor cursor = levelsDocument.find(QStringLiteral("level%1").arg(level));
            QVERIFY(!cursor.isNull());
            QCOMPARE(cursor.blockFormat().headingLevel(), level);
            QCOMPARE(cursor.charFormat().fontFamilies(), oldH3Style.charFormat().fontFamilies());
            QCOMPARE(glyphFamilies(cursor), legacyFamilies);
            QCOMPARE(cursor.charFormat().property(QTextFormat::FontSizeAdjustment), oldH3Style.charFormat().property(QTextFormat::FontSizeAdjustment));
            QVERIFY(cursor.charFormat().fontWeight() >= QFont::Bold);
            const QJsonArray pixels = glyphSizes(cursor);
            QVERIFY(!pixels.isEmpty());
            for (const QJsonValue &size : pixels) QVERIFY(qAbs(size.toDouble() - legacyPixels.first().toDouble()) < 0.05);
        }
        for (int level = 1; level <= 6; ++level) {
            const QString dialect = QStringLiteral("section-level%1").arg(level);
            const QString sectionTitle = QStringLiteral("Se beiga la conchugazión ") + dialect + QStringLiteral(" d'este berbo.");
            const QJsonObject sectionEntry{{QStringLiteral("kind"), QStringLiteral("language")},
                {QStringLiteral("sections"), QJsonArray{
                    QJsonObject{{QStringLiteral("title"), QStringLiteral("Compact section control")}, {QStringLiteral("level"), 2}, {QStringLiteral("blocks"), QJsonArray{}}},
                    QJsonObject{{QStringLiteral("title"), sectionTitle}, {QStringLiteral("level"), level},
                        {QStringLiteral("blocks"), QJsonArray{heading(dialect, 1, level)}}}}}};
            QTextDocument compactDocument;
            compactDocument.setHtml(window.entryHtml(sectionEntry));
            compactDocument.setTextWidth(560);
            compactDocument.documentLayout()->documentSize();
            const QTextCursor control = compactDocument.find(QStringLiteral("Compact section control"));
            const QTextCursor rich = compactDocument.find(dialect);
            QVERIFY(!control.isNull() && !rich.isNull());
            qInfo().noquote() << "COMPACT_HEADING_FONT_METRICS" << QJsonDocument(QJsonObject{
                {QStringLiteral("level"), level},
                {QStringLiteral("size_adjustment"), rich.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
                {QStringLiteral("control_h2_size_adjustment"), control.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
                {QStringLiteral("requested_point_size"), rich.charFormat().fontPointSize()},
                {QStringLiteral("control_h2_requested_point_size"), control.charFormat().fontPointSize()},
                {QStringLiteral("resolved_glyph_families"), glyphFamilies(rich)},
                {QStringLiteral("control_h2_resolved_glyph_families"), glyphFamilies(control)},
                {QStringLiteral("glyph_pixel_sizes"), glyphSizes(rich)},
                {QStringLiteral("control_h2_glyph_pixel_sizes"), glyphSizes(control)}}).toJson(QJsonDocument::Compact);
            QCOMPARE(rich.charFormat().property(QTextFormat::FontSizeAdjustment), control.charFormat().property(QTextFormat::FontSizeAdjustment));
            QCOMPARE(rich.blockFormat().headingLevel(), level);
            QCOMPARE(rich.blockFormat().leftMargin(), 30.0);
            QCOMPARE(rich.charFormat().fontFamilies(), control.charFormat().fontFamilies());
            QCOMPARE(rich.charFormat().fontPointSize(), control.charFormat().fontPointSize());
            QCOMPARE(glyphFamilies(rich), glyphFamilies(control));
            QCOMPARE(glyphSizes(rich), glyphSizes(control));
        }
        const QJsonObject ben = heading(QStringLiteral("benasquesa"), 1);
        const QJsonObject rib = heading(QStringLiteral("ribagorzana"), 2);
        QTextDocument direct;
        direct.setHtml(window.blockHtml(ben) + window.blockHtml(rib)
            + window.blockHtml(heading(QStringLiteral("fallback"), 0, 99)) + QStringLiteral("<h3>Old heading control</h3>"));
        const QTextCursor first = direct.find(QStringLiteral("la conchugazión benasquesa"));
        const QTextCursor second = direct.find(QStringLiteral("la conchugazión ribagorzana"));
        QVERIFY(!first.isNull() && !second.isNull());
        QCOMPARE(first.blockFormat().headingLevel(), 4);
        QCOMPARE(first.blockFormat().leftMargin(), 30.0);
        QCOMPARE(second.blockFormat().leftMargin(), 46.0);
        QCOMPARE(direct.find(QStringLiteral("fallback")).blockFormat().headingLevel(), 3);
        QCOMPARE(first.charFormat().property(QTextFormat::FontSizeAdjustment), direct.find(QStringLiteral("Old heading control")).charFormat().property(QTextFormat::FontSizeAdjustment));
        QCOMPARE(first.charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
        QCOMPARE(QUrl(first.charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
        QVERIFY(first.charFormat().fontItalic());
        QVERIFY(first.charFormat().fontWeight() >= QFont::Bold);
        QVERIFY(!direct.toPlainText().contains(QStringLiteral(":Se beiga")));
        const QString title = QStringLiteral("Se beiga la conchugazión benasquesa d'este berbo.");
        const QJsonObject plain{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4}, {QStringLiteral("depth"), 1},
            {QStringLiteral("list_path"), QStringLiteral(":")}, {QStringLiteral("spans"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("Plain indented heading")}}}}};
        const QJsonObject entry{{QStringLiteral("kind"), QStringLiteral("language")}, {QStringLiteral("title"), QStringLiteral("templlar")},
            {QStringLiteral("sections"), QJsonArray{
                QJsonObject{{QStringLiteral("title"), title}, {QStringLiteral("level"), 4}, {QStringLiteral("blocks"), QJsonArray{ben}}},
                QJsonObject{{QStringLiteral("title"), QStringLiteral("Plain indented heading")}, {QStringLiteral("level"), 4}, {QStringLiteral("blocks"), QJsonArray{plain}}}}}};
        QTextDocument document;
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(title), 1);
        QCOMPARE(document.toPlainText().count(QStringLiteral("Plain indented heading")), 1);
        const QTextCursor companion = document.find(QStringLiteral("la conchugazión benasquesa"));
        QCOMPARE(companion.blockFormat().headingLevel(), 4);
        QCOMPARE(companion.blockFormat().leftMargin(), 30.0);
        QCOMPARE(companion.charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
        QCOMPARE(QUrl(companion.charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
        QVERIFY(hasAnchor(&document, QStringLiteral("section-0")));
        QVERIFY(window.entryHtml(entry).contains(QStringLiteral("href='section:0'")));
        window.collapsedSections_.insert(0);
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(title), 1);
        QCOMPARE(document.find(QStringLiteral("la conchugazión benasquesa")).charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
        QCOMPARE(QUrl(document.find(QStringLiteral("la conchugazión benasquesa")).charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
    }

    void headingFixtureRendersNarrowLtrAndRtlWithoutClipping() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        const auto section = [](const QString &label, const QString &target, const QString &direction, int depth, bool companion) {
            QJsonObject span{{QStringLiteral("kind"), target.isEmpty() ? QStringLiteral("text") : QStringLiteral("link")},
                {QStringLiteral("text"), label}, {QStringLiteral("target"), target}, {QStringLiteral("direction"), direction},
                {QStringLiteral("bold"), !target.isEmpty()}, {QStringLiteral("italic"), true}};
            QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4},
                {QStringLiteral("depth"), depth}, {QStringLiteral("list_path"), QString(depth, QChar(':'))},
                {QStringLiteral("spans"), QJsonArray{span}}};
            return QJsonObject{{QStringLiteral("title"), companion ? label : QStringLiteral("Ordinary heading control")},
                {QStringLiteral("level"), 4}, {QStringLiteral("blocks"), QJsonArray{heading}}};
        };
        window.resize(580, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QJsonObject sourceResponse = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        for (const QString &direction : {QStringLiteral("ltr"), QStringLiteral("rtl")}) {
            const QString linked = direction == QStringLiteral("ltr")
                ? QStringLiteral("Se beiga la conchugazión benasquesa d'este berbo.")
                : QString::fromUtf8("عنوان عربي طويل لاختبار التفاف النص واتجاه القراءة");
            const QJsonObject entry{{QStringLiteral("kind"), QStringLiteral("language")}, {QStringLiteral("title"), QStringLiteral("Heading renderer fixture")},
                {QStringLiteral("sections"), QJsonArray{
                    section(linked, QStringLiteral("templlar/conj.BEN"), direction, 1, true),
                    section(QStringLiteral("Plain indented companion"), {}, direction, 1, true),
                    section(QStringLiteral("Ordinary source heading retains depth"), {}, direction, 1, false)}}};
            QJsonObject response = sourceResponse;
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson());
            QCoreApplication::processEvents();
            const QString frame = QStringLiteral(".tmp/ui-screenshots/heading-companion-%1-580.png").arg(direction);
            QVERIFY(window.grab().save(frame));
            QCOMPARE(window.size(), QSize(580, 480));
            QVERIFY(window.reading_->viewport()->width() > 100);
            QVERIFY(window.reading_->viewport()->height() > 100);
            QCOMPARE(window.reading_->horizontalScrollBar()->maximum(), 0);
            const QTextCursor link = window.reading_->document()->find(linked);
            QVERIFY2(!link.isNull(), qPrintable(window.reading_->toPlainText()));
            QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
            QCOMPARE(QUrl(link.charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
            QCOMPARE(link.blockFormat().leftMargin(), 30.0);
            QCOMPARE(link.blockFormat().headingLevel(), 4);
            QCOMPARE(window.reading_->toPlainText().count(linked), 1);
            QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Plain indented companion")), 1);
            const QTextCursor ordinary = window.reading_->document()->find(QStringLiteral("Ordinary source heading retains depth"));
            QVERIFY(!ordinary.isNull());
            QCOMPARE(ordinary.blockFormat().headingLevel(), 4);
            QCOMPARE(ordinary.blockFormat().leftMargin(), 30.0);
            window.reading_->setTextCursor(ordinary); window.reading_->ensureCursorVisible();
            QCoreApplication::processEvents();
            const QString lowerFrame = QStringLiteral(".tmp/ui-screenshots/heading-ordinary-%1-580.png").arg(direction);
            QVERIFY(window.grab().save(lowerFrame));
        }
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


    void poemLinesPreserveBlankLinesStylesAndLinks() {
        MainWindow window{QString()};
        const auto text = [](const QString &value, const QString &classes = QString()) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), value}, {QStringLiteral("classes"), classes}};
        };
        const QString marked = QStringLiteral("wikidict-poem");
        const QString indented = marked + QStringLiteral(" wikidict-poem-indent-2");
        const auto br = [](const QString &classes) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("line_break")},
                {QStringLiteral("classes"), classes}};
        };
        QJsonObject bold = text(QStringLiteral("Styled "), indented);
        bold.insert(QStringLiteral("bold"), true);
        QJsonObject link = text(QStringLiteral("cat"), indented);
        link.insert(QStringLiteral("kind"), QStringLiteral("link"));
        link.insert(QStringLiteral("target"), QStringLiteral("cat#Noun"));
        const QString padding = QString(2, QChar(0x00a0));
        const QJsonArray spans{text(QStringLiteral("Lead")), br({}), bold, link, br(indented),
            br(marked), text(padding + QStringLiteral("End"), marked), br(marked)};
        const QJsonObject block{{QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), spans}};
        const QJsonObject original = block;
        QTextDocument document;
        document.setTextWidth(360);
        document.setHtml(window.blockHtml(block));
        QString plain = document.toPlainText();
        plain.replace(QChar(0x00a0), QChar(' '));
        QCOMPARE(plain, QStringLiteral("Lead\nStyled cat\n\n  End\n"));
        QVERIFY(document.toRawText().contains(padding + QStringLiteral("End")));
        const QTextCursor styled = document.find(QStringLiteral("Styled "));
        const QTextCursor linked = document.find(QStringLiteral("cat"));
        QVERIFY(!styled.isNull() && !linked.isNull());
        QCOMPARE(styled.block().position(), linked.block().position()); // A style/link boundary cannot create a new line.
        QVERIFY(styled.charFormat().fontWeight() >= QFont::Bold);
        QCOMPARE(linked.charFormat().anchorHref(), QStringLiteral("dict:cat%23Noun"));
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        QVERIFY(qAbs(styled.blockFormat().leftMargin() - 2 * em) < 0.1);
        QCOMPARE(styled.blockFormat().rightMargin(), 0.0);
        QCOMPARE(document.blockCount(), 5);
        QVERIFY(document.lastBlock().text().isEmpty());
        QCOMPARE(block, original);

        // A boundary break is one line boundary, not an extra stanza.
        QTextDocument boundary;
        boundary.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Before")), br({}),
                text(QStringLiteral("Verse"), marked), br({}), text(QStringLiteral("After"))}}}));
        QCOMPARE(boundary.toPlainText(), QStringLiteral("Before\nVerse\nAfter"));
        QCOMPARE(boundary.blockCount(), 3);

        // Ordinary unmarked output remains the existing inline path.
        QTextDocument ordinary;
        ordinary.setHtml(window.spansHtml(QJsonArray{text(QStringLiteral("Ordinary")), br({}),
            text(QStringLiteral("line"))}));
        QCOMPARE(ordinary.toPlainText(), QStringLiteral("Ordinary\nline"));
        QCOMPARE(ordinary.blockCount(), 1);
    }

    void poemIndentFollowsEnclosingDirectionOnWrappedLines() {
        MainWindow window{QString()};
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        for (const bool rtl : {false, true}) {
            const QString words = rtl
                ? QStringLiteral("אבגד הוזח טיכל מנסע פצקר שתאב גדוז חטיכ למנס עפצק רשתא בגדו זחטי כלמנ סעפצ קרשת")
                : QStringLiteral("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma");
            const QString classes = QStringLiteral("wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-") +
                (rtl ? QStringLiteral("rtl") : QStringLiteral("ltr"));
            // A child's opposite isolate must not change the enclosing line's margin.
            const QJsonObject span{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), words}, {QStringLiteral("classes"), classes},
                {QStringLiteral("direction"), rtl ? QStringLiteral("ltr") : QStringLiteral("rtl")}};
            QTextDocument document;
            QFont font = document.defaultFont();
            font.setPointSize(window.readingPointSize_);
            document.setDefaultFont(font);
            document.setTextWidth(230);
            document.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{span}}}));
            (void) document.documentLayout()->documentSize();
            const QTextCursor located = document.find(words.left(4));
            QVERIFY(!located.isNull());
            const QTextBlock block = located.block();
            QVERIFY(block.isValid());
            QCOMPARE(block.blockFormat().layoutDirection(), rtl ? Qt::RightToLeft : Qt::LeftToRight);
            QVERIFY(qAbs(block.blockFormat().leftMargin() - (rtl ? 0 : 2 * em)) < 0.1);
            QVERIFY(qAbs(block.blockFormat().rightMargin() - (rtl ? 2 * em : 0)) < 0.1);
            const QTextLayout *layout = block.layout();
            QVERIFY(layout && layout->lineCount() >= 2);
            const qreal available = document.textWidth() - 2 * document.documentMargin() - 2 * em;
            for (int i = 0; i < layout->lineCount(); ++i) {
                const QTextLine line = layout->lineAt(i);
                QVERIFY(line.isValid());
                QVERIFY(line.width() <= available + 0.5);
                QVERIFY(line.width() > 0);
            }
            const QString raw = document.toRawText();
            QVERIFY(raw.contains(words)); // No spaces or indentation characters were injected.
        }
    }

    void poemLinesRetainCellCaptionAndOuterIndentContexts() {
        MainWindow window{QString()};
        const auto spans = [](const QString &text, int depth) {
            return QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("classes"),
                    QStringLiteral("wikidict-poem wikidict-poem-indent-%1").arg(depth)}}};
        };
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        const QJsonObject cell{{QStringLiteral("spans"), spans(QStringLiteral("Cell verse"), 2)}};
        const QJsonObject table{{QStringLiteral("caption"), spans(QStringLiteral("Caption verse"), 1)},
            {QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        QTextDocument document;
        document.setTextWidth(400);
        document.setHtml(window.tableHtml(table, 0));
        const QTextCursor caption = document.find(QStringLiteral("Caption verse"));
        const QTextCursor content = document.find(QStringLiteral("Cell verse"));
        QVERIFY(!caption.isNull() && !content.isNull());
        QVERIFY(qAbs(caption.blockFormat().leftMargin() - em) < 0.1);
        QVERIFY(qAbs(content.blockFormat().leftMargin() - 2 * em) < 0.1);
        QCOMPARE(document.toPlainText().count(QStringLiteral("Caption verse")), 1);
        QCOMPARE(document.toPlainText().count(QStringLiteral("Cell verse")), 1);

        QTextDocument nested;
        nested.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("indent")},
            {QStringLiteral("depth"), 2}, {QStringLiteral("spans"), spans(QStringLiteral("Nested verse"), 2)}}));
        const QTextCursor verse = nested.find(QStringLiteral("Nested verse"));
        QVERIFY(!verse.isNull());
        QVERIFY(qAbs(verse.blockFormat().leftMargin() - (46 + 2 * em)) < 0.1);

        // Noncanonical or excessive numbers preserve text but cannot select arbitrary margins.
        for (const QString &number : {QStringLiteral("0"), QStringLiteral("33"), QStringLiteral("02"),
                QStringLiteral("-1"), QStringLiteral("999999999999999999999")}) {
            const QJsonArray malformed{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QStringLiteral("Bounded verse")},
                {QStringLiteral("classes"), QStringLiteral("wikidict-poem wikidict-poem-indent-") + number}}};
            QTextDocument bounded;
            bounded.setHtml(window.spansHtml(malformed));
            QCOMPARE(bounded.toPlainText(), QStringLiteral("Bounded verse"));
            QCOMPARE(bounded.begin().blockFormat().leftMargin(), 0.0);
            QCOMPARE(bounded.begin().blockFormat().rightMargin(), 0.0);
        }
        QTextDocument maximum;
        maximum.setHtml(window.spansHtml(spans(QStringLiteral("Maximum verse"), 32)));
        QVERIFY(qAbs(maximum.begin().blockFormat().leftMargin() - 32 * em) < 0.1);
    }


    void poemMetadataAndRawLineFeedsFollowTheCanonicalContract() {
        MainWindow window{QString()};
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        const auto span = [](const QString &text, const QString &classes) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("classes"), classes}};
        };
        const QString mark = QStringLiteral("wikidict-poem");
        const QString one = mark + QStringLiteral(" wikidict-poem-indent-1");
        const QString two = mark + QStringLiteral(" wikidict-poem-indent-2");
        QJsonObject raw = span(QStringLiteral("First\n\nSecond"), one);
        raw.insert(QStringLiteral("trail"), QStringLiteral("\nTail\n"));
        raw.insert(QStringLiteral("kind"), QStringLiteral("link"));
        raw.insert(QStringLiteral("target"), QStringLiteral("cat#Noun"));
        raw.insert(QStringLiteral("bold"), true);
        const QJsonObject original = raw;
        QTextDocument lines;
        lines.setHtml(window.spansHtml(QJsonArray{raw}));
        QCOMPARE(lines.toPlainText(), QStringLiteral("First\n\nSecond\nTail\n"));
        QCOMPARE(lines.blockCount(), 5);
        for (const QString &word : {QStringLiteral("First"), QStringLiteral("Second"), QStringLiteral("Tail")}) {
            const QTextCursor found = lines.find(word);
            QVERIFY(!found.isNull());
            QCOMPARE(found.charFormat().anchorHref(), QStringLiteral("dict:cat%23Noun"));
            QVERIFY(found.charFormat().fontWeight() >= QFont::Bold);
            const qreal expected = word == QStringLiteral("First") ? em : 0.0;
            QVERIFY(qAbs(found.blockFormat().leftMargin() - expected) < 0.1);
        }
        QCOMPARE(raw, original);
        QJsonObject br{{QStringLiteral("kind"), QStringLiteral("line_break")}, {QStringLiteral("classes"), one}};
        lines.setHtml(window.spansHtml(QJsonArray{raw, br}));
        QCOMPARE(lines.toPlainText(), QStringLiteral("First\n\nSecond\nTail\n\n"));
        QCOMPARE(lines.blockCount(), 6);
        lines.setHtml(window.spansHtml(QJsonArray{span(QStringLiteral("First\n"), one),
            span(QStringLiteral("New wrapper"), two)}));
        const QTextCursor separatelyWrapped = lines.find(QStringLiteral("New wrapper"));
        QVERIFY(!separatelyWrapped.isNull());
        QVERIFY(qAbs(separatelyWrapped.blockFormat().leftMargin() - 2 * em) < 0.1);

        const QList<QJsonArray> invalidIndent{
            QJsonArray{span(QStringLiteral("Left"), two + QStringLiteral(" wikidict-poem-indent-2"))},
            QJsonArray{span(QStringLiteral("Left"), two), span(QStringLiteral("Right"), one)},
            QJsonArray{span(QStringLiteral("Left"), two), span(QStringLiteral("Right"), mark)},
            QJsonArray{span(QStringLiteral("Left"), mark + QStringLiteral(" wikidict-poem-indent-+3"))},
            QJsonArray{span(QStringLiteral("Left"), mark + QStringLiteral(" wikidict-poem-indent-"))}
        };
        for (const QJsonArray &value : invalidIndent) {
            QTextDocument document;
            document.setHtml(window.spansHtml(value));
            QVERIFY(document.toPlainText().startsWith(QStringLiteral("Left")));
            QCOMPARE(document.begin().blockFormat().leftMargin(), 0.0);
            QCOMPARE(document.begin().blockFormat().rightMargin(), 0.0);
        }
        const QList<QJsonArray> invalidDirection{
            QJsonArray{span(QStringLiteral("Default direction"), two + QStringLiteral(" wikidict-poem-dir-rtl wikidict-poem-dir-rtl"))},
            QJsonArray{span(QStringLiteral("Default direction"), two + QStringLiteral(" wikidict-poem-dir-ltr wikidict-poem-dir-rtl"))},
            QJsonArray{span(QStringLiteral("Default direction"), two + QStringLiteral(" wikidict-poem-dir-sideways"))},
            QJsonArray{span(QStringLiteral("Default "), two + QStringLiteral(" wikidict-poem-dir-rtl")),
                span(QStringLiteral("direction"), two)}
        };
        for (const QJsonArray &value : invalidDirection) {
            QTextDocument document;
            document.setHtml(window.spansHtml(value));
            QCOMPARE(document.toPlainText(), QStringLiteral("Default direction"));
            QVERIFY(qAbs(document.begin().blockFormat().leftMargin() - 2 * em) < 0.1);
            QCOMPARE(document.begin().blockFormat().rightMargin(), 0.0);
        }
        for (const QString &classes : {QStringLiteral("not-wikidict-poem wikidict-poem-indent-2"),
                QStringLiteral("wikidict-poem") + QChar(0x00a0) + QStringLiteral("wikidict-poem-indent-2")}) {
            QTextDocument document;
            document.setHtml(window.spansHtml(QJsonArray{span(QStringLiteral("Ordinary"), classes)}));
            QCOMPARE(document.toPlainText(), QStringLiteral("Ordinary"));
            QCOMPARE(document.begin().blockFormat().leftMargin(), 0.0);
        }
    }


    void poemPrefixesStayOnTheFirstLineAndDefaultDirectionIsTheContainer() {
        MainWindow window{QString()};
        const QString marked = QStringLiteral("wikidict-poem wikidict-poem-indent-2");
        const auto span = [](const QString &text, const QString &classes = QString()) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("classes"), classes}};
        };
        const QJsonArray mixed{span(QStringLiteral("Lead")),
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("line_break")}},
            span(QStringLiteral("Verse"), marked)};
        for (const QString &kind : {QStringLiteral("definition"), QStringLiteral("list_item"), QStringLiteral("example")}) {
            const QString prefix = kind == QStringLiteral("definition") ? QStringLiteral("7")
                : kind == QStringLiteral("list_item") ? QStringLiteral("7.") : QStringLiteral("Example:");
            const QJsonObject block{{QStringLiteral("kind"), kind}, {QStringLiteral("number"), QStringLiteral("7")},
                {QStringLiteral("depth"), 1}, {QStringLiteral("spans"), mixed}};
            QTextDocument document;
            document.setTextWidth(360);
            document.setHtml(window.blockHtml(block));
            QCOMPARE(document.toPlainText(), prefix + QStringLiteral(" Lead\nVerse"));
            QCOMPARE(document.blockCount(), 2);
            const QTextCursor label = document.find(prefix);
            const QTextCursor lead = document.find(QStringLiteral("Lead"));
            const QTextCursor verse = document.find(QStringLiteral("Verse"));
            QVERIFY(!label.isNull() && !lead.isNull() && !verse.isNull());
            QCOMPARE(label.block().position(), lead.block().position());
            QVERIFY(verse.block().position() > lead.block().position());
            if (kind == QStringLiteral("definition")) QVERIFY(label.charFormat().fontWeight() >= QFont::Bold);
            if (kind == QStringLiteral("example")) QVERIFY(label.charFormat().fontItalic());
            QVERIFY(!lead.charFormat().fontItalic());
        }
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        for (const bool rtlContainer : {false, true}) {
            window.reading_->setLayoutDirection(rtlContainer ? Qt::RightToLeft : Qt::LeftToRight);
            QJsonObject child = span(rtlContainer ? QStringLiteral("English child") : QStringLiteral("אבגד"), marked);
            child.insert(QStringLiteral("direction"), rtlContainer ? QStringLiteral("ltr") : QStringLiteral("rtl"));
            QTextDocument document;
            document.setHtml(window.spansHtml(QJsonArray{child}));
            const QTextBlock block = document.begin();
            QCOMPARE(block.blockFormat().layoutDirection(), rtlContainer ? Qt::RightToLeft : Qt::LeftToRight);
            QVERIFY(qAbs(block.blockFormat().leftMargin() - (rtlContainer ? 0 : 2 * em)) < 0.1);
            QVERIFY(qAbs(block.blockFormat().rightMargin() - (rtlContainer ? 2 * em : 0)) < 0.1);
            QVERIFY(document.toRawText().contains(child.value(QStringLiteral("text")).toString()));
        }
    }


    void poemReferencePrefixKeepsItsFirstLineAnchorAndMediaNavigation() {
        MainWindow window{QString()};
        const QJsonObject lead{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Lead")}, {QStringLiteral("target"), QStringLiteral("cat#Noun")},
            {QStringLiteral("classes"), QStringLiteral("wikidict-poem wikidict-poem-indent-1")},
            {QStringLiteral("bold"), true}};
        const QJsonObject br{{QStringLiteral("kind"), QStringLiteral("line_break")},
            {QStringLiteral("classes"), QStringLiteral("wikidict-poem wikidict-poem-indent-1")}};
        const QJsonObject caption{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Poem caption")},
            {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
            {QStringLiteral("classes"), QStringLiteral("wikidict-media\twikidict-poem wikidict-poem-indent-2")}};
        const QJsonObject reference{{QStringLiteral("number"), 4}, {QStringLiteral("group_number"), 2},
            {QStringLiteral("group"), QStringLiteral("note <one>")},
            {QStringLiteral("spans"), QJsonArray{lead, br, caption}}};
        const QJsonObject ordinary{{QStringLiteral("number"), 5}, {QStringLiteral("group_number"), 3},
            {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QStringLiteral("Ordinary citation")}}}}};
        const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Poem references")},
            {QStringLiteral("kind"), QStringLiteral("supplemental")}, {QStringLiteral("sections"), QJsonArray{}},
            {QStringLiteral("references"), QJsonArray{reference, ordinary}},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                {QStringLiteral("file"), QStringLiteral("Tone.ogg")}, {QStringLiteral("caption"), QStringLiteral("Poem caption")}}}}};
        QTextDocument document;
        document.setTextWidth(360);
        document.setHtml(window.entryHtml(entry));
        const QString plain = document.toPlainText();
        QVERIFY(plain.contains(QStringLiteral("[note <one> 2] Lead\nPoem caption")));
        QVERIFY(plain.contains(QStringLiteral("[3] Ordinary citation")));
        QCOMPARE(plain.count(QStringLiteral("Poem caption")), 1);
        QVERIFY(plain.contains(QStringLiteral("Tone.ogg")));
        QVERIFY(hasAnchor(&document, QStringLiteral("reference-4")));
        QVERIFY(hasAnchor(&document, QStringLiteral("reference-5")));
        const QTextCursor label = document.find(QStringLiteral("[note <one> 2]"));
        const QTextCursor first = document.find(QStringLiteral("Lead"));
        const QTextCursor second = document.find(QStringLiteral("Poem caption"));
        QVERIFY(!label.isNull() && !first.isNull() && !second.isNull());
        QCOMPARE(label.block().position(), first.block().position());
        QCOMPARE(first.block().next().position(), second.block().position());
        QVERIFY(first.charFormat().fontWeight() >= QFont::Bold);
        QCOMPARE(first.charFormat().anchorHref(), QStringLiteral("dict:cat%23Noun"));
        QCOMPARE(second.charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        QVERIFY(qAbs(first.block().blockFormat().leftMargin() - em) < 0.1);
        QVERIFY(qAbs(second.block().blockFormat().leftMargin() - 2 * em) < 0.1);
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

    void referenceFragmentsKeepBodiesWithoutNoteDestinations() {
        MainWindow window{QString()};
        window.resize(780, 480);
        const auto text = [](const QString &value) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}};
        };
        const auto note = [&](qint64 number, int ordinal, const QString &body) {
            return QJsonObject{{QStringLiteral("number"), number}, {QStringLiteral("group_number"), ordinal},
                {QStringLiteral("group"), QStringLiteral("note <one>")}, {QStringLiteral("spans"), QJsonArray{text(body)}}};
        };
        QJsonObject styled = text(QStringLiteral("Fragment café "));
        styled.insert(QStringLiteral("italic"), true);
        const QJsonObject media{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Fragment image")},
            {QStringLiteral("target"), QStringLiteral("File:Fragment_image.svg")},
            {QStringLiteral("classes"), QStringLiteral("wikidict-media")}, {QStringLiteral("bold"), true}};
        const QJsonObject fragment{{QStringLiteral("kind"), QStringLiteral("fragment")},
            {QStringLiteral("number"), 2}, {QStringLiteral("group_number"), QJsonValue::Null},
            {QStringLiteral("name"), QString()}, {QStringLiteral("group"), QStringLiteral("note <one>")},
            {QStringLiteral("spans"), QJsonArray{styled, media}}};
        QJsonObject later = note(3, 2, QStringLiteral("Later numbered body"));
        later.insert(QStringLiteral("kind"), QStringLiteral("note"));
        const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Reference items")},
            {QStringLiteral("kind"), QStringLiteral("supplemental")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Body")},
                {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                    {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Padding body ").repeated(500))}}}}}}}},
            {QStringLiteral("references"), QJsonArray{fragment, note(1, 1, QStringLiteral("First numbered body")), later,
                note(4294967294LL, 3, QStringLiteral("Large stable identity"))}},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")},
                {QStringLiteral("file"), QStringLiteral("Fragment image.svg")}, {QStringLiteral("caption"), QStringLiteral("Fragment image")}}}}};
        const QByteArray stored = QJsonDocument(entry).toJson(QJsonDocument::Compact);
        const QString html = window.entryHtml(entry);
        QTextDocument document;
        document.setHtml(html);
        const QString plain = document.toPlainText();
        QVERIFY(plain.contains(QStringLiteral("Fragment café Fragment image")));
        QVERIFY(plain.contains(QStringLiteral("[note <one> 1] First numbered body")));
        QVERIFY(plain.contains(QStringLiteral("[note <one> 2] Later numbered body")));
        QVERIFY(!plain.contains(QStringLiteral("[note <one> 0]")));
        QVERIFY(plain.indexOf(QStringLiteral("Fragment café")) < plain.indexOf(QStringLiteral("First numbered body")));
        QVERIFY(plain.indexOf(QStringLiteral("First numbered body")) < plain.indexOf(QStringLiteral("Later numbered body")));
        QVERIFY(document.find(QStringLiteral("Fragment café")).charFormat().fontItalic());
        QVERIFY(html.contains(QStringLiteral("dict:File%3AFragment_image.svg")));
        QVERIFY(!hasAnchor(&document, QStringLiteral("reference-2")));
        for (const QString &id : {QStringLiteral("reference-1"), QStringLiteral("reference-3"), QStringLiteral("reference-4294967294")})
            QVERIFY(hasAnchor(&document, id));
        QCOMPARE(QJsonDocument(entry).toJson(QJsonDocument::Compact), stored);

        // Only note IDs are citation destinations, independently of footer position.
        window.currentEntry_ = entry;
        window.reading_->setHtml(html);
        window.show();
        QTRY_VERIFY(window.reading_->verticalScrollBar()->maximum() > 0);
        window.jumpToFragment(QStringLiteral("reference-3"));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Later numbered body")));
        const int before = window.reading_->verticalScrollBar()->value();
        window.jumpToFragment(QStringLiteral("reference-2"));
        QCOMPARE(window.reading_->verticalScrollBar()->value(), before);
        QJsonObject legacy = entry;
        legacy.insert(QStringLiteral("references"), QJsonArray{note(7, 4, QStringLiteral("Legacy body"))});
        QJsonObject explicitNote = note(7, 4, QStringLiteral("Legacy body"));
        explicitNote.insert(QStringLiteral("kind"), QStringLiteral("note"));
        QJsonObject explicitEntry = legacy;
        explicitEntry.insert(QStringLiteral("references"), QJsonArray{explicitNote});
        QCOMPARE(window.entryHtml(legacy), window.entryHtml(explicitEntry));
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        window.show();
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-reference-fragments.png")));
    }

    void embeddedMediaCaptionKeepsTypedPresentationWithoutPlainDuplicate() {
        MainWindow window{QString()};
        const QString caption = QStringLiteral("Styled caption");
        const QJsonObject span{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), caption}, {QStringLiteral("target"), QStringLiteral("File:Caption_image.svg")},
            {QStringLiteral("classes"), QStringLiteral("note\twikidict-media")},
            {QStringLiteral("bold"), true}, {QStringLiteral("italic"), true},
            {QStringLiteral("language"), QStringLiteral("fr")}, {QStringLiteral("direction"), QStringLiteral("rtl")}};
        const QJsonObject block{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{span}}};
        QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Media fixture")}, {QStringLiteral("kind"), QStringLiteral("supplemental")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Gallery")},
                {QStringLiteral("level"), 3}, {QStringLiteral("blocks"), QJsonArray{block}}}}},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")},
                {QStringLiteral("file"), QStringLiteral("Caption image.svg")}, {QStringLiteral("caption"), caption}}}}};
        const QJsonObject original = entry;
        const auto visibleText = [](const QTextDocument &document) {
            QString text = document.toPlainText();
            for (ushort control = 0x2066; control <= 0x2069; ++control) text.remove(QChar(control));
            return text;
        };
        const QString html = window.entryHtml(entry);
        QVERIFY(html.contains(QStringLiteral("lang=\"fr\"")));
        QVERIFY(html.contains(QStringLiteral("dir=\"rtl\"")));
        QTextDocument document;
        document.setHtml(html);
        QCOMPARE(visibleText(document).count(caption), 1);
        const QTextCursor styled = document.find(caption);
        QVERIFY(!styled.isNull());
        QVERIFY(styled.charFormat().fontWeight() >= QFont::Bold);
        QVERIFY(styled.charFormat().fontItalic());
        QCOMPARE(styled.charFormat().anchorHref(), QStringLiteral("dict:File%3ACaption_image.svg"));
        QVERIFY(document.toRawText().contains(QString(QChar(0x2067)) + caption + QChar(0x2069)));
        QVERIFY(document.toPlainText().contains(QStringLiteral("Caption image.svg"))); // Metadata link remains available.
        QCOMPARE(entry, original);

        window.collapsedSections_.insert(0);
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Hidden body needs its metadata fallback.
        QVERIFY(!document.find(caption).charFormat().fontItalic());
        window.collapsedSections_.clear();
        entry.insert(QStringLiteral("sections"), QJsonArray{});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Metadata-only legacy entry.
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{span});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Preamble captions also retain their typed owner.
        QJsonObject first = span, second = span;
        first.insert(QStringLiteral("text"), QStringLiteral("Styled "));
        second.insert(QStringLiteral("text"), QStringLiteral("caption"));
        second.insert(QStringLiteral("bold"), false);
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{first, second});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Styled pieces share one caption owner.
        QJsonObject otherCaption = span;
        otherCaption.insert(QStringLiteral("text"), QStringLiteral("Different authored label"));
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{otherCaption});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // A different same-file label does not own this caption.
        QVERIFY(document.toPlainText().contains(QStringLiteral("Different authored label")));
        QJsonObject unrelated = span;
        unrelated.insert(QStringLiteral("classes"), QStringLiteral("not-wikidict-media"));
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{unrelated});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 2); // Ordinary prose is not a media caption owner.
        entry.remove(QStringLiteral("preamble_spans"));
        for (const QString &kind : {QStringLiteral("blank"), QStringLiteral("rule")}) {
            QJsonObject hidden = block;
            hidden.insert(QStringLiteral("kind"), kind);
            entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Ignored")},
                {QStringLiteral("blocks"), QJsonArray{hidden}}}});
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(visibleText(document).count(caption), 1);
            QVERIFY(!document.find(caption).charFormat().fontItalic()); // Ignored fields cannot own the caption.
        }
        QJsonObject table = block;
        table.insert(QStringLiteral("table"), QJsonObject{{QStringLiteral("caption"), QJsonArray{}}, {QStringLiteral("rows"), QJsonArray{}}});
        entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Table")},
            {QStringLiteral("blocks"), QJsonArray{table}}}});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1);
        QVERIFY(!document.find(caption).charFormat().fontItalic()); // tableHtml ignores the adjacent block.spans.
        table.insert(QStringLiteral("table"), QJsonObject{{QStringLiteral("rows"), QJsonArray{QJsonObject{
            {QStringLiteral("cells"), QJsonArray{QJsonObject{{QStringLiteral("spans"), QJsonArray{span}}}}}}}}});
        entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Table")},
            {QStringLiteral("blocks"), QJsonArray{table}}}});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1);
        QVERIFY(document.find(caption).charFormat().fontItalic()); // An actual rendered cell does own it.
    }

    void embeddedMultilineMediaCaptionKeepsTypedBreaksAndCollapsedFallback() {
        MainWindow window{QString()};
        for (bool poem : {false, true}) {
            const QString classes = poem
                ? QStringLiteral("wikidict-media\twikidict-poem wikidict-poem-indent-2")
                : QStringLiteral("note wikidict-media");
            const QString firstText = QStringLiteral("First caption");
            const QString secondText = QStringLiteral("Second verse");
            const QString caption = firstText + (poem ? QStringLiteral("\n\n") : QStringLiteral("\n")) + secondText;
            const QJsonObject first{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), firstText}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
                {QStringLiteral("classes"), classes}, {QStringLiteral("bold"), true}};
            const QJsonObject second{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), secondText}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
                {QStringLiteral("classes"), classes}, {QStringLiteral("italic"), true}};
            const QJsonObject ownedBreak{{QStringLiteral("kind"), QStringLiteral("line_break")},
                {QStringLiteral("text"), QStringLiteral("\n")}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
                {QStringLiteral("classes"), classes}};
            QJsonArray spans{first, ownedBreak};
            if (poem) spans.append(ownedBreak); // A blank stanza remains part of this caption.
            spans.append(second);
            const QJsonObject block{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), spans}};
            const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Multiline media")},
                {QStringLiteral("kind"), QStringLiteral("supplemental")},
                {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Gallery")},
                    {QStringLiteral("level"), 3}, {QStringLiteral("blocks"), QJsonArray{block}}}}},
                {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                    {QStringLiteral("file"), QStringLiteral("Tone.ogg")}, {QStringLiteral("caption"), caption}}}}};
            const QJsonObject original = entry;
            QTextDocument document;
            document.setTextWidth(360);
            document.setHtml(window.entryHtml(entry));
            const QString plain = document.toPlainText();
            QVERIFY(plain.contains(caption));
            QCOMPARE(plain.count(firstText), 1);
            QCOMPARE(plain.count(secondText), 1);
            const QTextCursor firstCursor = document.find(firstText);
            const QTextCursor secondCursor = document.find(secondText);
            QVERIFY(!firstCursor.isNull() && !secondCursor.isNull());
            QVERIFY(firstCursor.charFormat().fontWeight() >= QFont::Bold);
            QVERIFY(secondCursor.charFormat().fontItalic());
            QCOMPARE(firstCursor.charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            QCOMPARE(secondCursor.charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            const QTextCursor fileCursor = document.find(QStringLiteral("Tone.ogg"));
            QVERIFY(!fileCursor.isNull());
            QCOMPARE(fileCursor.charFormat().anchorHref(), QStringLiteral("https://commons.wikimedia.org/wiki/File:Tone.ogg"));
            QCOMPARE(entry, original);

            window.collapsedSections_.insert(0);
            document.setHtml(window.entryHtml(entry));
            const QString collapsed = document.toPlainText();
            QCOMPARE(collapsed.count(firstText), 1);
            QCOMPARE(collapsed.count(secondText), 1);
            QVERIFY(collapsed.simplified().contains(caption.simplified()));
            QVERIFY(document.find(firstText).charFormat().fontWeight() < QFont::Bold);
            QVERIFY(!document.find(secondText).charFormat().fontItalic());
            QVERIFY(document.find(firstText).charFormat().anchorHref().isEmpty());
            QVERIFY(!document.find(QStringLiteral("Tone.ogg")).isNull());
            QCOMPARE(entry, original);
            window.collapsedSections_.clear();
        }
    }

    void explicitMediaOwnersPreserveCaptionActionsAndExactFileIdentity() {
        MainWindow window(fixture_, QStringLiteral("dog"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        const QString tone = QStringLiteral("wikidict-media wikidict-media-file-546f6e652e6f6767");
        const QString other = QStringLiteral("wikidict-media wikidict-media-file-4f746865722e6f6767");
        const QString caption = QStringLiteral("A domestic cat and external.");
        const auto span = [](const QString &text, const QString &target, const QString &classes,
                             const QString &kind = QStringLiteral("link")) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text},
                {QStringLiteral("target"), target}, {QStringLiteral("classes"), classes}, {QStringLiteral("bold"), true}};
        };
        const auto media = [](const QString &file, const QString &text) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                {QStringLiteral("file"), file}, {QStringLiteral("caption"), text}};
        };
        const QJsonArray mixed{span(QStringLiteral("A "), QStringLiteral("File:Tone.ogg"), tone),
            span(QStringLiteral("domestic cat"), QStringLiteral("cat"), tone),
            span(QStringLiteral(" and "), QStringLiteral("File:Tone.ogg"), tone),
            span(QStringLiteral("external"), QStringLiteral("https://example.org"), tone, QStringLiteral("external_link")),
            span(QStringLiteral("."), QStringLiteral("File:Tone.ogg"), tone)};
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("dog"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("preamble_spans"), mixed);
        entry.insert(QStringLiteral("sections"), QJsonArray{});
        entry.insert(QStringLiteral("references"), QJsonArray{});
        entry.insert(QStringLiteral("media"), QJsonArray{media(QStringLiteral("Tone.ogg"), caption)});
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QCOMPARE(window.reading_->toPlainText().count(caption), 1);
        const QTextCursor cat = window.reading_->document()->find(QStringLiteral("domestic cat"), 0, QTextDocument::FindCaseSensitively);
        QVERIFY(!cat.isNull());
        QCOMPARE(cat.charFormat().anchorHref(), QStringLiteral("dict:cat"));
        QVERIFY(cat.charFormat().fontWeight() >= QFont::Bold);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("external")).charFormat().anchorHref(), QStringLiteral("https://example.org"));
        QVERIFY(!window.reading_->document()->find(QStringLiteral("Tone.ogg")).isNull());
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto clearHandler = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("https://example.org")));
        QCOMPARE(receiver.opened, QList<QUrl>{QUrl(QStringLiteral("https://example.org"))});
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:cat")));
        QTRY_COMPARE(title(window), QStringLiteral("cat"));

        // Equal visible labels cannot transfer ownership to another media record.
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{
            span(QStringLiteral("same"), QStringLiteral("cat"), tone),
            span(QStringLiteral("\n"), {}, {}, QStringLiteral("line_break")),
            span(QStringLiteral("same"), QStringLiteral("dog"), other)});
        entry.insert(QStringLiteral("media"), QJsonArray{
            media(QStringLiteral("Tone.ogg"), QStringLiteral("same")),
            media(QStringLiteral("Other.ogg"), QStringLiteral("same"))});
        QTextDocument document;
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2);
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{span(QStringLiteral("same"), QStringLiteral("cat"), tone)});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2); // Other still needs its fallback.

        const QString unicode = QStringLiteral("wikidict-media wikidict-media-file-c38963686f20f09f948a2e6f6767");
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{span(QStringLiteral("same"), QStringLiteral("cat"), unicode)});
        entry.insert(QStringLiteral("media"), QJsonArray{media(QStringLiteral("Écho 🔊.ogg"), QStringLiteral("same"))});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 1);

        const QString token = QStringLiteral("wikidict-media-file-546f6e652e6f6767");
        const QString otherToken = QStringLiteral("wikidict-media-file-4f746865722e6f6767");
        entry.insert(QStringLiteral("media"), QJsonArray{media(QStringLiteral("Tone.ogg"), QStringLiteral("same"))});
        for (const QString &bad : {QStringLiteral("wikidict-media-file-"), QStringLiteral("wikidict-media-file-0"),
                QStringLiteral("wikidict-media-file-ff"), QStringLiteral("wikidict-media-file-546F6E652E6F6767"),
                QStringLiteral("wikidict-media-file-556e6b6e6f776e2e6f6767"), token + QChar(' ') + token,
                token + QChar(' ') + otherToken}) {
            entry.insert(QStringLiteral("preamble_spans"), QJsonArray{
                span(QStringLiteral("same"), QStringLiteral("File:Tone.ogg"), QStringLiteral("wikidict-media ") + bad)});
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2);
        }
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{
            span(QStringLiteral("same"), QStringLiteral("File:Tone.ogg"), QStringLiteral("not-wikidict-media ") + token)});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2);
    }

    void mediaCaptionOwnershipStopsAtUnrelatedBreaksAndOtherFiles() {
        MainWindow window{QString()};
        const QString firstText = QStringLiteral("First caption");
        const QString secondText = QStringLiteral("Second verse");
        const QString marked = QStringLiteral("wikidict-media wikidict-poem");
        const QJsonObject first{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), firstText}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
            {QStringLiteral("classes"), marked}};
        QJsonObject second = first;
        second.insert(QStringLiteral("text"), secondText);
        const auto boundary = [](const QString &classes, const QString &target) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("line_break")},
                {QStringLiteral("text"), QStringLiteral("\n")}, {QStringLiteral("classes"), classes},
                {QStringLiteral("target"), target}};
        };
        const QJsonArray boundaries{
            boundary(QStringLiteral("wikidict-poem"), QStringLiteral("File:Tone.ogg")),
            boundary(QStringLiteral("not-wikidict-media wikidict-poem"), QStringLiteral("File:Tone.ogg")),
            boundary(marked, QStringLiteral("File:Other.ogg")),
            boundary(marked, QString())};
        for (const QJsonValue &separator : boundaries) {
            const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Separate captions")},
                {QStringLiteral("kind"), QStringLiteral("supplemental")},
                {QStringLiteral("preamble_spans"), QJsonArray{first, separator, second}},
                {QStringLiteral("sections"), QJsonArray{}},
                {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                    {QStringLiteral("file"), QStringLiteral("Tone.ogg")},
                    {QStringLiteral("caption"), firstText + QStringLiteral("\n") + secondText}}}}};
            const QJsonObject original = entry;
            QTextDocument document;
            document.setHtml(window.entryHtml(entry));
            const QString plain = document.toPlainText();
            QVERIFY(plain.contains(firstText + QStringLiteral("\n") + secondText));
            // These separately owned pieces cannot suppress the full metadata caption.
            QCOMPARE(plain.count(firstText), 2);
            QCOMPARE(plain.count(secondText), 2);
            QCOMPARE(document.find(firstText).charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            QCOMPARE(document.find(secondText).charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            QCOMPARE(entry, original);
        }
    }

    void crossEntrySectionLinkKeepsFragmentThroughRealLookup() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Dog noun section")}, {QStringLiteral("target"), QStringLiteral("dog#Noun")}}});
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QCOMPARE(window.reading_->verticalScrollBar()->value(), 0); // Known initial destination position.
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog%23Noun")));
        QCOMPARE(title(window), QStringLiteral("dog"));
        QCOMPARE(window.search_->text(), QStringLiteral("dog"));
        const QJsonObject realDog = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("dog"))).object()
            .value(QStringLiteral("entries")).toArray().first().toObject();
        QCOMPARE(window.currentEntry_, realDog);
        const QJsonArray realSections = realDog.value(QStringLiteral("sections")).toArray();
        int nounSection = -1;
        for (qsizetype i = 0; i < realSections.size(); ++i) {
            if (realSections[i].toObject().value(QStringLiteral("title")).toString() == QStringLiteral("Noun")) {
                nounSection = static_cast<int>(i);
                break;
            }
        }
        qInfo() << "Real dog Noun section index" << nounSection << "section count" << realSections.size();
        QVERIFY(nounSection >= 0);
        const int nounChoice = window.sections_->findText(QStringLiteral("Noun"));
        QVERIFY(nounChoice >= 0);
        QCOMPARE(window.sections_->itemData(nounChoice).toInt(), nounSection);
        // Qt imports the empty section anchor onto the block's character format.
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-%1").arg(nounSection)));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Noun")));
        QVERIFY(window.reading_->verticalScrollBar()->value() > 0);

        // The same selected navigation test checks the source-edition ISBN route.
        QTemporaryDir directory(QStringLiteral(".tmp/ui-booksources-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString path = QDir(directory.path()).absolutePath();
        const QString ordinary = QStringLiteral("Special:BookSources/not-an-isbn");
        QVERIFY(prepareCaseTitleFixture(fixture_, path, {QStringLiteral("cat"), ordinary}));
        const QString library = path + QStringLiteral("/library");
        QFile marker(library + QStringLiteral("/.desktop-edition"));
        QVERIFY(marker.open(QIODevice::WriteOnly));
        QCOMPARE(marker.write("frwiktionary-20261001\n"), qint64(22));
        marker.close();
        MainWindow bookWindow(library, QStringLiteral("cat"));
        bookWindow.resize(780, 480);
        bookWindow.show();
        QTRY_VERIFY_WITH_TIMEOUT(!bookWindow.loading_ && bookWindow.api_, 30000);
        QTRY_COMPARE(title(bookWindow), QStringLiteral("cat"));
        QCOMPARE(bookWindow.api_->language(), QStringLiteral("English"));
        QCOMPARE(LibraryStorage::sourceHost(bookWindow.api_->root()), QStringLiteral("fr.wiktionary.org"));
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        const auto link = [](const QString &target) {
            return QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), QStringLiteral("ISBN route")}, {QStringLiteral("target"), target}}};
        };
        const QString prefix = QStringLiteral("Special:BookSources/");
        qsizetype openedCount = 0;
        for (const QString &isbn : {QStringLiteral("123456789X"), QStringLiteral("0000000000"),
                                   QStringLiteral("9780306406157"), QStringLiteral("979123456789X")}) {
            const QString target = prefix + isbn;
            bookWindow.reading_->setHtml(bookWindow.spansHtml(link(target)));
            QVERIFY(clickAnchor(bookWindow.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target))));
            ++openedCount;
            QCOMPARE(receiver.opened.size(), openedCount);
            QCOMPARE(receiver.opened.last(), QUrl(QStringLiteral("https://fr.wiktionary.org/wiki/") +
                QString::fromLatin1(QUrl::toPercentEncoding(target))));
            QCOMPARE(title(bookWindow), QStringLiteral("cat"));
            QCOMPARE(bookWindow.search_->text(), QStringLiteral("cat"));
        }
        QCOMPARE(receiver.opened.size(), qsizetype(4));
        for (const QString &target : {prefix + QStringLiteral("123456789x"), prefix + QStringLiteral("1234567890123"),
                                     prefix + QStringLiteral("9780306406157#Noun"), prefix + QStringLiteral("9780306406157?q=1"),
                                     prefix + QStringLiteral("9780306406157/path"), prefix + QStringLiteral("%31%32%33%34%35%36%37%38%39X"),
                                     prefix + QStringLiteral("123-456789X"), prefix + QStringLiteral("١٢٣٤٥٦٧٨٩X"),
                                     QStringLiteral("special:BookSources/123456789X")}) {
            bookWindow.reading_->setHtml(bookWindow.spansHtml(link(target)));
            QVERIFY(clickAnchor(bookWindow.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target))));
            QCOMPARE(receiver.opened.size(), qsizetype(4));
            QCOMPARE(title(bookWindow), QStringLiteral("cat"));
        }
        // An unlabeled root must not guess the lexical language's source edition.
        QVERIFY(LibraryStorage::sourceHost(window.api_->root()).isEmpty());
        const QString unknownTarget = prefix + QStringLiteral("123456789X");
        window.reading_->setHtml(window.spansHtml(link(unknownTarget)));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(unknownTarget))));
        QCOMPARE(receiver.opened.size(), qsizetype(4));
        QCOMPARE(title(window), QStringLiteral("dog"));
        // A real ordinary title sharing the prefix still uses exact dictionary lookup.
        bookWindow.reading_->setHtml(bookWindow.spansHtml(link(ordinary)));
        QVERIFY(clickAnchor(bookWindow.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(ordinary))));
        QCOMPARE(title(bookWindow), ordinary);
        QVERIFY(bookWindow.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QCOMPARE(receiver.opened.size(), qsizetype(4));
    }

    void compiledLinkComponentsKeepLiteralTitleThroughMouseAndKeyboard() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-link-components-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString literal = QStringLiteral("cat#Noun");
        const QString opaque = QString::fromUtf8("Title%23?x&Ω#literal");
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(), {QStringLiteral("cat"), literal, opaque}));
        MainWindow window(directory.path() + QStringLiteral("/library"), QStringLiteral("cat"));
        window.resize(640, 600); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const auto span = [](const QString &target, const QJsonValue &fragment) {
            QJsonObject value{{"kind", "link"}, {"text", "Component link"}, {"target", target}};
            if (!fragment.isUndefined()) value.insert("target_fragment", fragment);
            return value;
        };
        struct Case { QString target; QJsonValue fragment; QString expectedTitle; bool keyboard; };
        const QList<Case> cases{
            {literal, QJsonValue(QJsonValue::Undefined), QStringLiteral("cat"), false},
            {literal, QJsonValue(QJsonValue::Null), QStringLiteral("cat"), true},
            {literal, QStringLiteral(""), literal, false},
            {literal, QStringLiteral("Noun"), literal, true},
            {opaque, QStringLiteral(""), opaque, true},
            {opaque, QString::fromUtf8("Noun#%23?&Ω"), opaque, false}
        };
        for (const Case &test : cases) {
            const bool separate = test.fragment.isString();
            QString href = QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(test.target));
            if (separate) href += QChar('#') + QString::fromLatin1(QUrl::toPercentEncoding(test.fragment.toString()));
            const QUrl transport(href);
            QCOMPARE(transport.hasFragment(), separate);
            QCOMPARE(transport.path(QUrl::FullyDecoded), test.target);
            if (separate) QCOMPARE(transport.fragment(QUrl::FullyDecoded), test.fragment.toString());
            window.reading_->setHtml(window.spansHtml(QJsonArray{span(test.target, test.fragment)}));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("Component link")).charFormat().anchorHref(), href);
            QSignalSpy activated(window.reading_, &QTextBrowser::anchorClicked);
            if (test.keyboard) {
                window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
                QTest::keyClick(window.reading_, Qt::Key_Home, Qt::ControlModifier);
                QTest::keyClick(window.reading_, Qt::Key_Tab);
                QVERIFY(window.reading_->textCursor().hasSelection());
                QTest::keyClick(window.reading_, Qt::Key_Return);
            } else QVERIFY(clickAnchor(window.reading_, href));
            QCOMPARE(activated.size(), qsizetype(1));
            QCOMPARE(activated.first().first().toUrl(), transport);
            QTRY_COMPARE(title(window), test.expectedTitle);
            QCOMPARE(window.search_->text(), test.expectedTitle);
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        }
        // Same-entry fragment-only actions still use the component, never the
        // literal title's '#' or a second percent-decoding pass.
        int nounSection = -1;
        const QJsonArray sections = window.currentEntry_.value(QStringLiteral("sections")).toArray();
        for (qsizetype i = 0; i < sections.size(); ++i)
            if (sections[i].toObject().value(QStringLiteral("title")).toString() == QStringLiteral("Noun")) nounSection = int(i);
        QVERIFY(nounSection >= 0);
        window.collapsedSections_.insert(nounSection);
        window.reading_->setHtml(window.spansHtml(QJsonArray{span(QString(), QStringLiteral("Noun"))}));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:#Noun")));
        QVERIFY(!window.collapsedSections_.contains(nounSection));
        QCOMPARE(title(window), opaque);
        QJsonObject invalid = span(literal, true);
        QVERIFY_EXCEPTION_THROWN(window.spansHtml(QJsonArray{invalid}), DictApiError);
        invalid = span(literal, QStringLiteral("")); invalid.insert("kind", "external_link");
        QVERIFY_EXCEPTION_THROWN(window.spansHtml(QJsonArray{invalid}), DictApiError);
    }

    void compiledBookSourceComponentsUseExactEditionTitleAndFragment() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-booksources-components-XXXXXX"));
        QVERIFY(directory.isValid());
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(), {QStringLiteral("cat")}));
        const QString library = directory.path() + QStringLiteral("/library");
        QFile marker(library + QStringLiteral("/.desktop-edition"));
        QVERIFY(marker.open(QIODevice::WriteOnly));
        QCOMPARE(marker.write("frwiktionary-20261001\n"), qint64(22)); marker.close();
        MainWindow window(library, QStringLiteral("cat"));
        window.resize(640, 600); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        const QString prefix = QStringLiteral("Special:Booksources/");
        const auto link = [](const QString &target, const QJsonValue &fragment) {
            QJsonObject value{{"kind", "link"}, {"text", "Book source"}, {"target", target}, {"bold", true}};
            if (!fragment.isUndefined()) value.insert("target_fragment", fragment);
            return value;
        };
        struct Case { QString title; QJsonValue fragment; QString expectedPage; QString expectedFragment; };
        const QList<Case> cases{
            {prefix + "9780306406157", QJsonValue(QJsonValue::Undefined), prefix + "9780306406157", {}},
            {prefix + "9780306406157#part", QStringLiteral(""), prefix + "9780306406157#part", {}},
            {prefix + QString::fromUtf8("%23?x&Ω#literal"), QString::fromUtf8("part#%23?x&Ω"), prefix + QString::fromUtf8("%23?x&Ω#literal"), QString::fromUtf8("part#%23?x&Ω")},
            {prefix + "legacy#part", QJsonValue(QJsonValue::Null), prefix + "legacy", "part"}
        };
        for (const Case &test : cases) {
            const QJsonObject value = link(test.title, test.fragment);
            QCOMPARE(value.value("kind").toString(), QStringLiteral("link"));
            window.reading_->setHtml(window.spansHtml(QJsonArray{value}));
            const QString href = window.reading_->document()->find(QStringLiteral("Book source")).charFormat().anchorHref();
            const qsizetype before = receiver.opened.size();
            if (before % 2) {
                window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
                QTest::keyClick(window.reading_, Qt::Key_Home, Qt::ControlModifier);
                QTest::keyClick(window.reading_, Qt::Key_Tab);
                QVERIFY(window.reading_->textCursor().hasSelection());
                QTest::keyClick(window.reading_, Qt::Key_Return);
            } else QVERIFY(clickAnchor(window.reading_, href));
            QCOMPARE(receiver.opened.size(), before + 1);
            const QUrl source = receiver.opened.last();
            QCOMPARE(source.host(), QStringLiteral("fr.wiktionary.org"));
            QCOMPARE(source.path(QUrl::FullyDecoded), QStringLiteral("/wiki/") + test.expectedPage);
            QCOMPARE(source.hasQuery(), false);
            QCOMPARE(source.hasFragment(), !test.expectedFragment.isEmpty());
            QCOMPARE(source.fragment(QUrl::FullyDecoded), test.expectedFragment);
            QCOMPARE(title(window), QStringLiteral("cat"));
        }
        MainWindow unlabeled(fixture_, QStringLiteral("cat"));
        unlabeled.resize(640, 600); unlabeled.show();
        QTRY_VERIFY_WITH_TIMEOUT(!unlabeled.loading_ && unlabeled.api_, 30000);
        QVERIFY(LibraryStorage::sourceHost(unlabeled.api_->root()).isEmpty());
        const qsizetype before = receiver.opened.size();
        unlabeled.reading_->setHtml(unlabeled.spansHtml(QJsonArray{link(prefix + "literal#title", QStringLiteral(""))}));
        const QString href = unlabeled.reading_->document()->find(QStringLiteral("Book source")).charFormat().anchorHref();
        QVERIFY(clickAnchor(unlabeled.reading_, href));
        QCOMPARE(receiver.opened.size(), before);
        QCOMPARE(title(unlabeled), QStringLiteral("cat"));
        QVERIFY(unlabeled.statusBar()->currentMessage().contains(QStringLiteral("source edition")));
    }

    void captionOnlyTablesAndFosteredParagraphsKeepVisibleDepth() {
        MainWindow window{QString()};
        const auto spans = [](const QString &text) { return QJsonArray{QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}; };
        const QJsonObject table{{QStringLiteral("caption"), spans(QStringLiteral("Only caption"))},
            {QStringLiteral("rows"), QJsonArray{}}};
        QTextDocument caption;
        caption.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")},
            {QStringLiteral("depth"), 2}, {QStringLiteral("list_path"), QStringLiteral("::")},
            {QStringLiteral("table"), table}}));
        const QTextCursor captionCursor = caption.find(QStringLiteral("Only caption"));
        QVERIFY(!captionCursor.isNull());
        QCOMPARE(caption.toPlainText().count(QStringLiteral("Only caption")), 1);
        QCOMPARE(captionCursor.block().blockFormat().leftMargin(), qreal(46));
        for (const int depth : {0, 1, 2}) {
            QTextDocument paragraph;
            paragraph.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("depth"), depth}, {QStringLiteral("list_path"), depth ? QStringLiteral("::") : QString()},
                {QStringLiteral("spans"), spans(QStringLiteral("Fostered paragraph"))}}));
            const QTextCursor cursor = paragraph.find(QStringLiteral("Fostered paragraph"));
            QVERIFY(!cursor.isNull());
            QCOMPARE(paragraph.toPlainText(), QStringLiteral("Fostered paragraph"));
            QCOMPARE(cursor.block().blockFormat().leftMargin(), qreal(depth == 0 ? 0 : 30 + (depth - 1) * 16));
        }
    }

    void typedSelfLinksStayBoldAndNonactionableAcrossCaptionAndCell() {
        // Client-only DPR-shaped fixture. This does not claim a corpus caption.
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const auto self = [](const QString &label) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), label}, {QStringLiteral("target"), QString()},
                {QStringLiteral("classes"), QStringLiteral("mw-selflink selflink")},
                {QStringLiteral("bold"), true}};
        };
        const auto text = [](const QString &value) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}};
        };
        const auto linked = [](const QString &label, const QString &target) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), label}, {QStringLiteral("target"), target}};
        };
        const auto html = [&](bool adjacent) {
            QJsonArray paragraph{text(QStringLiteral("CLIENT-ONLY SELF-LINK FIXTURE: "))};
            QJsonArray caption;
            if (adjacent) {
                const QJsonObject file = linked(QStringLiteral("Fixture file"), QStringLiteral("File:caption.png"));
                paragraph.append(file); paragraph.append(text(QStringLiteral(" ")));
                caption.append(file); caption.append(text(QStringLiteral(" ")));
            }
            paragraph.append(self(QStringLiteral("Paragraph self")));
            caption.append(self(QStringLiteral("Caption self")));
            if (adjacent) {
                caption.append(text(QStringLiteral(" ")));
                caption.append(linked(QStringLiteral("Next dog"), QStringLiteral("dog")));
            }
            const QJsonObject cell{{QStringLiteral("spans"), QJsonArray{self(QStringLiteral("Cell self"))}}};
            const QJsonObject row{{QStringLiteral("cells"), QJsonArray{cell}}};
            const QJsonObject table{{QStringLiteral("caption"), caption}, {QStringLiteral("rows"), QJsonArray{row}}};
            return window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                       {QStringLiteral("spans"), paragraph}})
                + window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")},
                       {QStringLiteral("table"), table}});
        };
        const QStringList labels{QStringLiteral("Paragraph self"), QStringLiteral("Caption self"), QStringLiteral("Cell self")};
        QSignalSpy activated(window.reading_, &QTextBrowser::anchorClicked);
        for (const int width : {580, 780}) {
            window.resize(width, 480);
            window.reading_->setHtml(html(false));
            window.reading_->setFocus();
            QTRY_VERIFY(window.reading_->hasFocus());
            QCOMPARE(window.size(), QSize(width, 480));
            for (const QString &label : labels) {
                const QTextCursor found = window.reading_->document()->find(label);
                QVERIFY(!found.isNull());
                QCOMPARE(window.reading_->toPlainText().count(label), 1);
                for (int at = found.selectionStart(); at < found.selectionEnd(); ++at) {
                    QTextCursor character(window.reading_->document());
                    character.setPosition(at);
                    character.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
                    QVERIFY(!character.charFormat().isAnchor());
                    QVERIFY(character.charFormat().anchorHref().isEmpty());
                    QVERIFY(character.charFormat().fontWeight() >= QFont::Bold);
                }
            }
            auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
            QVERIFY(accessible && accessible->textInterface());
            const QString accessibleText = accessible->textInterface()->text(0, accessible->textInterface()->characterCount());
            for (const QString &label : labels) QCOMPARE(accessibleText.count(label), 1);
            QTextCursor selfCursor = window.reading_->document()->find(QStringLiteral("Caption self"));
            selfCursor.setPosition(selfCursor.selectionStart() + 3);
            window.reading_->setTextCursor(selfCursor);
            window.reading_->ensureCursorVisible();
            const QPoint point = window.reading_->cursorRect(selfCursor).center();
            QVERIFY(window.reading_->viewport()->rect().contains(point));
            QVERIFY(window.reading_->anchorAt(point).isEmpty());
            QTest::mouseClick(window.reading_->viewport(), Qt::LeftButton, Qt::NoModifier, point);
            QTest::keyClick(window.reading_, Qt::Key_Return);
            QCOMPARE(activated.count(), 0);
            QCOMPARE(title(window), QStringLiteral("cat"));
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-client-selflink-caption-%1.png").arg(width)));
            // With no anchors in this fixture, Tab must leave the reader.
            window.reading_->setFocus();
            QTest::keyClick(window.reading_, Qt::Key_Tab);
            QTRY_VERIFY(QApplication::focusWidget() && QApplication::focusWidget() != window.reading_);
        }
        window.reading_->setHtml(html(true));
        for (const QString &label : labels) {
            const QTextCursor found = window.reading_->document()->find(label);
            QVERIFY(!found.isNull());
            QVERIFY(!found.charFormat().isAnchor());
            QVERIFY(found.charFormat().anchorHref().isEmpty());
        }
        // Preceding file action cannot leak into ordinary caption text; the
        // adjacent real dictionary action still opens the existing dog fixture.
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("dog"), 30000);
        QVERIFY(activated.count() >= 1);
    }

    void typedSpanForegroundPreservesBenDistinctionsAndLinkedActions() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const auto colored = [](const QString &text, const QString &foreground, bool bold = false) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text},
                {QStringLiteral("foreground"), foreground}, {QStringLiteral("bold"), bold}};
        };
        // Exact authored BEN key words and forms, including a color-only form.
        const QJsonArray sourceSpans{
            colored(QStringLiteral("berda"), QStringLiteral("#008000")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("asul"), QStringLiteral("#1c39bb")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("turquesa"), QStringLiteral("#01796f")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiguanebabe"), QStringLiteral("#008000"), true),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiguanebem"), QStringLiteral("#1c39bb"), true),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiga aiguanebau"), QStringLiteral("#1c39bb")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiguanebats"), QStringLiteral("#01796f"), true),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" plain neighbor ")}},
            // Typed link control, not a claim that this link color occurs in BEN.
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Follow")},
                {QStringLiteral("target"), QStringLiteral("dog")}, {QStringLiteral("foreground"), QStringLiteral("#008000")},
                {QStringLiteral("italic"), true}}
        };
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme);
            window.applyTheme();
            window.reading_->setHtml(window.spansHtml(QJsonArray{QJsonObject{{QStringLiteral("text"), QStringLiteral("plain neighbor")}}}));
            const QBrush defaultForeground = window.reading_->document()->find(QStringLiteral("plain neighbor")).charFormat().foreground();
            window.reading_->setHtml(window.spansHtml(sourceSpans));
            for (const QJsonValue &value : sourceSpans) {
                const QJsonObject span = value.toObject();
                if (!span.contains(QStringLiteral("foreground"))) continue;
                const QTextCursor found = window.reading_->document()->find(span.value(QStringLiteral("text")).toString());
                QVERIFY(!found.isNull());
                QCOMPARE(found.charFormat().foreground().color(), QColor(span.value(QStringLiteral("foreground")).toString()));
                QCOMPARE(found.charFormat().fontWeight() >= QFont::Bold, span.value(QStringLiteral("bold")).toBool());
            }
            QCOMPARE(window.reading_->document()->find(QStringLiteral("plain neighbor")).charFormat().foreground(), defaultForeground);
            const QTextCharFormat link = window.reading_->document()->find(QStringLiteral("Follow")).charFormat();
            QVERIFY(link.isAnchor());
            QCOMPARE(link.anchorHref(), QStringLiteral("dict:dog"));
            QVERIFY(link.fontItalic());
        }
        QSignalSpy activated(window.reading_, &QTextBrowser::anchorClicked);
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("dog"), 30000);
        QVERIFY(activated.count() >= 1);

        const QJsonObject ordinary{{QStringLiteral("text"), QStringLiteral("unchanged")}};
        const QString unchanged = window.spansHtml(QJsonArray{ordinary});
        for (const QJsonValue &invalid : {QJsonValue(), QJsonValue(false), QJsonValue(123),
                QJsonValue(QStringLiteral("green")), QJsonValue(QStringLiteral("#008000;")),
                QJsonValue(QStringLiteral("#1C39BB")), QJsonValue(QStringLiteral("#080")),
                QJsonValue(QStringLiteral("#008000ff")), QJsonValue(QStringLiteral("#gggggg"))}) {
            QJsonObject span = ordinary;
            span.insert(QStringLiteral("foreground"), invalid);
            QCOMPARE(window.spansHtml(QJsonArray{span}), unchanged);
        }
    }

    void typedCellBackgroundPreservesBleohTableAndLinks() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        // Source-authored Bleoh row backgrounds and named swatch overrides;
        // the stored API supplies canonical RGB, not CSS or replacement labels.
        const QStringList labels{QStringLiteral("blæc"), QStringLiteral("grǣg"), QStringLiteral("hwīt"), QStringLiteral("seolfor"), QStringLiteral("gold"), QStringLiteral("rēod"), QStringLiteral("basu"), QStringLiteral("hǣwen"), QStringLiteral("grēne"), QStringLiteral("geolu"), QStringLiteral("geolorēad")};
        const QStringList targets{QStringLiteral("blæc"), QStringLiteral("grǣg"), QStringLiteral("hwīt"), QStringLiteral("Seolfor"), QStringLiteral("gold"), QStringLiteral("rēod"), QStringLiteral("basu"), QStringLiteral("hǣwen"), QStringLiteral("grēne"), QStringLiteral("geolu"), QStringLiteral("geolorēad")};
        const QStringList colors{QStringLiteral("#000000"), QStringLiteral("#808080"), QStringLiteral("#ffffff"), QStringLiteral("#c0c0c0"), QStringLiteral("#ffd700"), QStringLiteral("#ff0000"), QStringLiteral("#800080"), QStringLiteral("#0000ff"), QStringLiteral("#008000"), QStringLiteral("#ffff00"), QStringLiteral("#ffa500")};
        QJsonArray rows;
        for (int index = 0; index < labels.size(); ++index) {
            const QJsonObject link{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), labels[index]}, {QStringLiteral("target"), targets[index]}};
            const QJsonObject blank{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QString(QChar(0x00a0))}};
            rows.append(QJsonObject{{QStringLiteral("cells"), QJsonArray{
                QJsonObject{{QStringLiteral("spans"), QJsonArray{link}}, {QStringLiteral("background"), QStringLiteral("#eeeeee")}},
                QJsonObject{{QStringLiteral("spans"), QJsonArray{blank}}, {QStringLiteral("background"), colors[index]}}
            }}});
        }
        window.reading_->setHtml(window.tableHtml(QJsonObject{{QStringLiteral("rows"), rows}}, 0));
        QTextTable *table = nullptr;
        for (QTextFrame *frame : window.reading_->document()->rootFrame()->childFrames())
            if (auto *candidate = qobject_cast<QTextTable *>(frame)) { table = candidate; break; }
        QVERIFY(table);
        QCOMPARE(table->rows(), 11);
        QCOMPARE(table->columns(), 2);
        for (int index = 0; index < labels.size(); ++index) {
            const QTextTableCell label = table->cellAt(index, 0);
            const QTextTableCell sample = table->cellAt(index, 1);
            QCOMPARE(label.format().background().color(), QColor(QStringLiteral("#eeeeee")));
            QCOMPARE(sample.format().background().color(), QColor(colors[index]));
            QCOMPARE(label.rowSpan(), 1);
            QCOMPARE(label.columnSpan(), 1);
            QCOMPARE(sample.rowSpan(), 1);
            QCOMPARE(sample.columnSpan(), 1);
            QCOMPARE(label.firstCursorPosition().block().text(), labels[index]);
            QCOMPARE(sample.firstCursorPosition().block().text(), QString(QChar(0x00a0)));
            const QTextFragment fragment = label.firstCursorPosition().block().begin().fragment();
            QVERIFY(fragment.isValid());
            QVERIFY(fragment.charFormat().isAnchor());
            QCOMPARE(fragment.charFormat().anchorHref(), QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(targets[index])));
        }
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Color sample")));

        const QJsonObject span{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("unchanged")}};
        const QJsonObject ordinary{{QStringLiteral("spans"), QJsonArray{span}}};
        const auto oneCellTable = [&](const QJsonObject &cell) {
            return QJsonObject{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        };
        const QString unchanged = window.tableHtml(oneCellTable(ordinary), 0);
        for (const QJsonValue &invalid : {QJsonValue(), QJsonValue(false), QJsonValue(123),
                QJsonValue(QStringLiteral("red")), QJsonValue(QStringLiteral("#FFF000")),
                QJsonValue(QStringLiteral("#ff0")), QJsonValue(QStringLiteral("#ffff0000")),
                QJsonValue(QStringLiteral("#gggggg")), QJsonValue(QStringLiteral("#ffff00;"))}) {
            QJsonObject cell = ordinary;
            cell.insert(QStringLiteral("background"), invalid);
            QCOMPARE(window.tableHtml(oneCellTable(cell), 0), unchanged);
        }
        QJsonObject colored = ordinary;
        colored.insert(QStringLiteral("background"), QStringLiteral("#000000"));
        window.reading_->setHtml(window.tableHtml(QJsonObject{{QStringLiteral("rows"), QJsonArray{
            QJsonObject{{QStringLiteral("cells"), QJsonArray{colored, ordinary}}}
        }}}, 0));
        table = nullptr;
        for (QTextFrame *frame : window.reading_->document()->rootFrame()->childFrames())
            if (auto *candidate = qobject_cast<QTextTable *>(frame)) { table = candidate; break; }
        QVERIFY(table);
        QCOMPARE(table->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#000000")));
        QCOMPARE(table->cellAt(0, 1).format().background().style(), Qt::NoBrush);
    }

    void spanBackgroundPreservesInnerPaintAndHeadingMetadata() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
        QVERIFY(accessible);
        auto *accessibleText = accessible->textInterface();
        QVERIFY(accessibleText);
        const auto attributesAt = [accessibleText](const QTextCursor &cursor) {
            int start = -1, end = -1;
            return accessibleText->attributes(cursor.selectionStart(), &start, &end).split(QChar(';'), Qt::SkipEmptyParts);
        };
        const auto painted = [](const QString &text, const QString &color) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("background"), color}};
        };
        QJsonObject link = painted(QStringLiteral("inner link"), QStringLiteral("#ffffe0"));
        link.insert(QStringLiteral("kind"), QStringLiteral("link"));
        link.insert(QStringLiteral("target"), QStringLiteral("dog"));
        link.insert(QStringLiteral("trail"), QStringLiteral("!"));
        link.insert(QStringLiteral("code"), true);
        QJsonObject breakTrail = painted(QStringLiteral("ignored break text"), QStringLiteral("#ff0000"));
        breakTrail.insert(QStringLiteral("kind"), QStringLiteral("line_break"));
        breakTrail.insert(QStringLiteral("trail"), QStringLiteral("break trail"));
        QJsonObject cellAuthoredInk = painted(QStringLiteral("cell authored ink"), QStringLiteral("#000000"));
        cellAuthoredInk.insert(QStringLiteral("foreground"), QStringLiteral("#123456"));
        const QJsonArray spans{link, QJsonObject{{QStringLiteral("text"), QStringLiteral(" plain neighbor")}}, breakTrail,
            painted(QStringLiteral("dark inner override"), QStringLiteral("#000000")), cellAuthoredInk,
            painted(QStringLiteral("   "), QStringLiteral("#00ff00"))};
        const QJsonObject cell{{QStringLiteral("background"), QStringLiteral("#fffdd0")}, {QStringLiteral("spans"), spans}};
        const QJsonObject table{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            window.reading_->setHtml(window.tableHtml(table, 0));
            const auto inner = window.reading_->document()->find(QStringLiteral("inner link!"));
            QVERIFY(!inner.isNull());
            QCOMPARE(inner.charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
            QVERIFY(inner.charFormat().isAnchor());
            const QString plain = window.reading_->toPlainText();
            QVERIFY(plain.contains(QStringLiteral("plain neighbor\nbreak trail")));
            QCOMPARE(plain.count(QStringLiteral("break trail")), 1);
            QVERIFY(!plain.contains(QStringLiteral("ignored break text")));
            const auto trail = window.reading_->document()->find(QStringLiteral("break trail"));
            QCOMPARE(trail.charFormat().background().color(), QColor(QStringLiteral("#ff0000")));
            QVERIFY(!trail.charFormat().isAnchor());
            const auto neighbor = window.reading_->document()->find(QStringLiteral("plain neighbor"));
            QCOMPARE(neighbor.charFormat().background().style(), Qt::NoBrush);
            QCOMPARE(neighbor.charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
            const auto darkInner = window.reading_->document()->find(QStringLiteral("dark inner override"));
            QCOMPARE(darkInner.charFormat().background().color(), QColor(QStringLiteral("#000000")));
            QCOMPARE(darkInner.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("cell authored ink")).charFormat().foreground().color(), QColor(QStringLiteral("#123456")));
            QCOMPARE(inner.charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
            QVERIFY(inner.charFormat().fontUnderline());
            QCOMPARE(trail.charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
            auto *rendered = qobject_cast<QTextTable *>(window.reading_->document()->rootFrame()->childFrames().first());
            QVERIFY(rendered);
            QCOMPARE(rendered->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#fffdd0")));
            QVERIFY(!neighbor.isNull());
            const auto neighborAttributes = attributesAt(neighbor);
            QVERIFY(neighborAttributes.contains(QStringLiteral("color:rgb(0,0,0)")));
            QVERIFY(neighborAttributes.contains(QStringLiteral("background-color:rgb(255,253,208)")));
            QVERIFY(!darkInner.isNull());
            const auto innerAttributes = attributesAt(darkInner);
            QVERIFY(innerAttributes.contains(QStringLiteral("color:rgb(255,255,255)")));
            QVERIFY(innerAttributes.contains(QStringLiteral("background-color:rgb(0,0,0)")));
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            window.resize(900, 700);
            QCoreApplication::processEvents();
            window.reading_->verticalScrollBar()->setValue(0);
            QCoreApplication::processEvents();
            QVERIFY(window.reading_->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-span-background-%1.png").arg(theme)));
        }
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            QJsonObject explicitInk = painted(QStringLiteral("authored ink"), QStringLiteral("#ffffe0"));
            explicitInk.insert(QStringLiteral("foreground"), QStringLiteral("#123456"));
            window.reading_->setHtml(window.spansHtml(QJsonArray{painted(QStringLiteral("dark paint"), QStringLiteral("#000000")), explicitInk,
                QJsonObject{{QStringLiteral("text"), QStringLiteral("theme neighbor")}}}));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("dark paint")).charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("authored ink")).charFormat().foreground().color(), QColor(QStringLiteral("#123456")));
            const auto themeNeighbor = window.reading_->document()->find(QStringLiteral("theme neighbor"));
            QVERIFY(!themeNeighbor.isNull());
            QCOMPARE(themeNeighbor.charFormat().foreground().style(), Qt::NoBrush);
            QCOMPARE(themeNeighbor.charFormat().background().style(), Qt::NoBrush);
            QVERIFY(!themeNeighbor.currentTable());
            const QColor base = window.reading_->palette().color(QPalette::Base);
            QVERIFY(attributesAt(themeNeighbor).contains(QStringLiteral("background-color:rgb(%1,%2,%3)")
                .arg(base.red()).arg(base.green()).arg(base.blue())));
        }
        for (const QString &invalid : {QStringLiteral("#FFFFE0"), QStringLiteral("#fff"), QStringLiteral("yellow"), QStringLiteral("#ffffe0\n")}) {
            window.reading_->setHtml(window.spansHtml(QJsonArray{painted(QStringLiteral("invalid paint"), invalid)}));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("invalid paint")).charFormat().background().style(), Qt::NoBrush);
        }
        const QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 3},
            {QStringLiteral("spans"), QJsonArray{painted(QStringLiteral("Noun"), QStringLiteral("#ffffe0"))}}};
        const QJsonObject section{{QStringLiteral("title"), QStringLiteral("Noun")}, {QStringLiteral("level"), 3},
            {QStringLiteral("blocks"), QJsonArray{heading, QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{painted(QStringLiteral("   "), QStringLiteral("#00ff00"))}}}}}};
        window.currentEntry_ = QJsonObject{{QStringLiteral("title"), QStringLiteral("Paint title")},
            {QStringLiteral("display_title"), QJsonArray{painted(QStringLiteral("Paint title"), QStringLiteral("#ffffe0"))}},
            {QStringLiteral("preamble_spans"), QJsonArray{painted(QStringLiteral("Paint preamble"), QStringLiteral("#ffffe0"))}},
            {QStringLiteral("references"), QJsonArray{QJsonObject{{QStringLiteral("number"), 1}, {QStringLiteral("group_number"), 1},
                {QStringLiteral("spans"), QJsonArray{painted(QStringLiteral("Paint reference"), QStringLiteral("#ffffe0"))}}}}},
            {QStringLiteral("sections"), QJsonArray{section}}};
        const QJsonObject response{{QStringLiteral("entries"), QJsonArray{window.currentEntry_}}};
        window.renderResponse(QJsonDocument(response).toJson(), false);
        QCOMPARE(window.title_->document()->find(QStringLiteral("Paint title")).charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
        for (const QString &label : {QStringLiteral("Paint preamble"), QStringLiteral("Paint reference")}) {
            const auto found = window.reading_->document()->find(label); QVERIFY(!found.isNull());
            QCOMPARE(found.charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
        }
        const auto noun = window.reading_->document()->find(QStringLiteral("Noun"));
        QVERIFY(!noun.isNull());
        QCOMPARE(noun.charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Noun")), 1);
        QVERIFY(window.entryHtml(window.currentEntry_).contains(QStringLiteral("background-color:#00ff00")));
    }

    void aliasImportAcceptsAnchoredAndPaintedSourceVersions() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-painted-alias-XXXXXX"));
        QVERIFY(directory.isValid());
        const auto varint = [](quint64 n) { QByteArray out; do { unsigned char b = n & 127; n >>= 7; if (n) b |= 128; out.append(char(b)); } while (n); return out; };
        for (const QByteArray &magic : {QByteArrayLiteral("DPR5"), QByteArrayLiteral("DPR6")}) {
            const QByteArray presentation = magic + QByteArray(28, '\0');
            QByteArray alias = QByteArrayLiteral("DAL1") + QByteArray(4, '\0') + char(1) + char(1) + QByteArray(4, '\0') + char(1);
            for (const QByteArray &field : {QByteArrayLiteral("Alias"), QByteArrayLiteral("Alias"), QByteArrayLiteral("en"), QByteArrayLiteral("Target"), QByteArrayLiteral("Target"), QByteArrayLiteral("en"), presentation})
                alias += varint(field.size()) + field;
            QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(8) + QByteArray("1\tAlias\0", 8) + varint(alias.size()) + alias;
            const QString source = directory.filePath(QString::fromLatin1(magic) + QStringLiteral(".wikblb"));
            QFile file(source); QVERIFY(file.open(QIODevice::WriteOnly)); QCOMPARE(file.write(bytes), bytes.size()); file.close();
            std::atomic_bool cancelled = false;
            const QString root = directory.filePath(QString::fromLatin1(magic) + QStringLiteral("-library"));
            auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            QVERIFY(prepared); LibraryStorage::commitImport(root, *prepared);
            QCOMPARE(LibraryStorage::installed(root).size(), qsizetype(1));
        }
    }

    void orderedCellBlocksKeepFlowHeadingContextAndChildGrid() {
        MainWindow window{QString()};
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        const auto text = [](const QString &value) { return QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        const auto block = [&](const QString &kind, const QString &value) { return QJsonObject{
            {QStringLiteral("kind"), kind}, {QStringLiteral("spans"), QJsonArray{text(value)}}}; };
        const auto table = [](const QJsonObject &cell) { return QJsonObject{{QStringLiteral("rows"), QJsonArray{
            QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}}; };
        QJsonObject heading = block(QStringLiteral("heading"), QStringLiteral("Cell heading"));
        heading.insert(QStringLiteral("level"), 4); heading.insert(QStringLiteral("anchor"), QStringLiteral("Cell_heading"));
        heading.insert(QStringLiteral("anchor_fallback"), QStringLiteral("Cell.20heading"));
        QJsonObject item = block(QStringLiteral("list_item"), QStringLiteral("Cell list body"));
        item.insert(QStringLiteral("number"), QStringLiteral("2")); item.insert(QStringLiteral("depth"), 1);
        item.insert(QStringLiteral("list_path"), QStringLiteral("#"));
        QJsonObject child = table(QJsonObject{{QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Child cell body"))}}});
        child.insert(QStringLiteral("geometry"), QJsonObject{{QStringLiteral("cell_padding"), 2},
            {QStringLiteral("width"), QJsonObject{{QStringLiteral("unit"), QStringLiteral("percent")}, {QStringLiteral("value"), 100}}}});
        QJsonObject linked = text(QStringLiteral("Cell linked body")); linked.insert(QStringLiteral("kind"), QStringLiteral("link"));
        linked.insert(QStringLiteral("target"), QStringLiteral("cat"));
        QJsonObject explicitInk = text(QStringLiteral("Authored cell ink")); explicitInk.insert(QStringLiteral("foreground"), QStringLiteral("#ff0000"));
        const QJsonArray contents{block(QStringLiteral("paragraph"), QStringLiteral("Before cell heading")), heading, item,
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("rule")}, {QStringLiteral("spans"), QJsonArray{}}},
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("depth"), 1}, {QStringLiteral("table"), child}},
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{linked, explicitInk}}},
            block(QStringLiteral("paragraph"), QStringLiteral("After cell table"))};
        const QJsonObject cell{{QStringLiteral("header"), true}, {QStringLiteral("background"), QStringLiteral("#000000")},
            {QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), contents}};
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            window.reading_->setHtml(window.tableHtml(table(cell), 0, 1, {}, QStringLiteral("block-0-0")));
            QTextDocument *document = window.reading_->document();
            const QString body = document->toPlainText();
            int previous = -1;
            for (const QString &part : {QStringLiteral("Before cell heading"), QStringLiteral("Cell heading"),
                     QStringLiteral("Cell list body"), QStringLiteral("Child cell body"), QStringLiteral("Cell linked body"),
                     QStringLiteral("After cell table")}) {
                QCOMPARE(body.count(part), 1); const int at = body.indexOf(part); QVERIFY(at > previous); previous = at;
            }
            QCOMPARE(document->find(QStringLiteral("Cell heading"), 0, QTextDocument::FindCaseSensitively).blockFormat().headingLevel(), 4);
            QCOMPARE(document->find(QStringLiteral("2."), 0, QTextDocument::FindCaseSensitively).charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            bool ruleFound = false;
            for (QTextBlock part = document->begin(); part.isValid(); part = part.next()) {
                if (!part.blockFormat().hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth)) continue;
                ruleFound = true;
                QVERIFY(part.blockFormat().hasProperty(QTextFormat::BackgroundBrush));
                QCOMPARE(part.blockFormat().background().color(), QColor(QStringLiteral("#ffffff")));
            }
            QVERIFY(ruleFound);
            QCOMPARE(document->find(QStringLiteral("Before cell heading")).charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QVERIFY(document->find(QStringLiteral("Before cell heading")).charFormat().fontWeight() >= QFont::Bold);
            const QTextCursor link = document->find(QStringLiteral("Cell linked body"));
            QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("dict:cat"));
            QCOMPARE(link.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QCOMPARE(document->find(QStringLiteral("Authored cell ink")).charFormat().foreground().color(), QColor(QStringLiteral("#ff0000")));
            QVERIFY(hasAnchor(document, QStringLiteral("block-0-0-row-0-cell-0-block-1")));
            auto *outer = qobject_cast<QTextTable *>(document->rootFrame()->childFrames().first()); QVERIFY(outer);
            QCOMPARE(outer->rows(), 1); QCOMPARE(outer->columns(), 1); QCOMPARE(outer->childFrames().size(), 1);
            auto *inner = qobject_cast<QTextTable *>(outer->childFrames().first()); QVERIFY(inner);
            QCOMPARE(inner->format().cellPadding(), qreal(2));
            QCOMPARE(inner->format().width().type(), QTextLength::PercentageLength); QCOMPARE(inner->format().width().rawValue(), qreal(100));
            QCOMPARE(inner->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#000000")));
            QApplication::processEvents();
            QCOMPARE(document->toPlainText(), body);
            QDir().mkpath(QStringLiteral(".tmp/ui-screenshots"));
            QVERIFY(window.reading_->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-cell-blocks-%1.png").arg(theme)));
        }
        QJsonObject paleCell = cell;
        paleCell.insert(QStringLiteral("background"), QStringLiteral("#ffeecc"));
        QTextDocument paleDocument;
        paleDocument.setHtml(window.tableHtml(table(paleCell), 0));
        QCOMPARE(paleDocument.find(QStringLiteral("2."), 0, QTextDocument::FindCaseSensitively).charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
        QCOMPARE(paleDocument.find(QStringLiteral("Authored cell ink")).charFormat().foreground().color(), QColor(QStringLiteral("#ff0000")));
        bool paleRuleFound = false;
        for (QTextBlock part = paleDocument.begin(); part.isValid(); part = part.next()) {
            if (!part.blockFormat().hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth)) continue;
            paleRuleFound = true;
            QVERIFY(part.blockFormat().hasProperty(QTextFormat::BackgroundBrush));
            QCOMPARE(part.blockFormat().background().color(), QColor(QStringLiteral("#000000")));
        }
        QVERIFY(paleRuleFound);
        QCOMPARE(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("rule")}}), QStringLiteral("<hr>"));
        QJsonObject caption = text(QStringLiteral("Inline cell caption"));
        caption.insert(QStringLiteral("kind"), QStringLiteral("link")); caption.insert(QStringLiteral("target"), QStringLiteral("File:Sample.svg"));
        caption.insert(QStringLiteral("classes"), QStringLiteral("wikidict-media"));
        const QJsonObject captionCell{{QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), QJsonArray{
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{caption}}}}}};
        const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Cell media")}, {QStringLiteral("kind"), QStringLiteral("supplemental")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Media owner")},
                {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("table"), table(captionCell)}}}}}}},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")}, {QStringLiteral("file"), QStringLiteral("Sample.svg")},
                {QStringLiteral("caption"), QStringLiteral("Inline cell caption")}}}}};
        QTextDocument media; media.setHtml(window.entryHtml(entry));
        QCOMPARE(media.toPlainText().count(QStringLiteral("Inline cell caption")), 1);
    }

    void orderedCellHeadingFragmentsStayInsideOwningSection() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        const auto text = [](const QString &value) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        const auto paragraph = [&](const QString &value) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{text(value)}}}; };
        const QString unicode(QChar(0x00e4));
        const QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 2},
            {QStringLiteral("anchor"), unicode}, {QStringLiteral("anchor_fallback"), QStringLiteral(".C3.A4")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Cell destination"))}}};
        const QJsonObject emptyHeading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 5},
            {QStringLiteral("anchor"), QStringLiteral("Empty_cell_heading")}, {QStringLiteral("spans"), QJsonArray{}}};
        const QJsonObject cell{{QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), QJsonArray{
            paragraph(QStringLiteral("Cell prefix")), heading, paragraph(QStringLiteral("CELL TARGET BODY")), emptyHeading}}};
        const QJsonObject table{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        const QJsonObject tableBlock{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("table"), table}};
        entry.insert(QStringLiteral("sections"), QJsonArray{
            QJsonObject{{QStringLiteral("title"), QStringLiteral("Other")}, {QStringLiteral("level"), 2},
                {QStringLiteral("anchor"), QStringLiteral("Other")}, {QStringLiteral("blocks"), QJsonArray{paragraph(QStringLiteral("OTHER BODY"))}}},
            QJsonObject{{QStringLiteral("title"), QStringLiteral("Cell owner")}, {QStringLiteral("level"), 2},
                {QStringLiteral("anchor"), QStringLiteral("Cell_owner")}, {QStringLiteral("blocks"), QJsonArray{tableBlock}}}});
        QJsonObject localLink{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("target"), QStringLiteral("#") + unicode},
            {QStringLiteral("text"), QStringLiteral("Read cell destination")}};
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{localLink});
        response.insert(QStringLiteral("entries"), QJsonArray{entry}); window.renderResponse(QJsonDocument(response).toJson(), true);
        QCOMPARE(window.sections_->count(), 3); // Cell-local headings are not promoted to top-level navigation.
        window.collapsedSections_ = {0, 1}; window.refreshReading(); window.jumpToFragment(unicode);
        QVERIFY(window.collapsedSections_.contains(0)); QVERIFY(!window.collapsedSections_.contains(1));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("CELL TARGET BODY")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-1-0-row-0-cell-0-block-1")));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Cell destination"), 0, QTextDocument::FindCaseSensitively).blockFormat().headingLevel(), 2);
        window.collapsedSections_.insert(1); window.refreshReading(); window.jumpToFragment(QStringLiteral(".C3.A4"));
        QVERIFY(!window.collapsedSections_.contains(1)); QVERIFY(textIsVisible(window.reading_, QStringLiteral("CELL TARGET BODY")));
        window.collapsedSections_.insert(1); window.refreshReading(); window.jumpToFragment(QStringLiteral("Empty_cell_heading"));
        QVERIFY(!window.collapsedSections_.contains(1));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-1-0-row-0-cell-0-block-3")));
    }

    void orderedCellAuthorityAndDepthAreValidated() {
        MainWindow window{QString()};
        const auto table = [](const QJsonObject &cell) { return QJsonObject{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}}; };
        const QJsonObject empty{{QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), QJsonArray{}}, {QStringLiteral("background"), QStringLiteral("#800080")}};
        QJsonObject legacy = empty; legacy.remove(QStringLiteral("blocks"));
        QCOMPARE(window.tableHtml(table(empty), 0), window.tableHtml(table(legacy), 0));
        QJsonObject invalid = empty; invalid.insert(QStringLiteral("blocks"), QStringLiteral("not blocks"));
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        invalid = empty; invalid.insert(QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("text"), QStringLiteral("ambiguous")}}});
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        invalid = empty; invalid.insert(QStringLiteral("nested_table"), table(legacy));
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        invalid = empty; invalid.insert(QStringLiteral("blocks"), QJsonArray{QStringLiteral("not a block")});
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        QJsonObject nested = table(empty);
        const auto wrap = [&](const QJsonObject &child) { return table(QJsonObject{{QStringLiteral("spans"), QJsonArray{}},
            {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("table"), child}}}}}); };
        for (int i = 1; i < 16; ++i) nested = wrap(nested);
        QVERIFY(!window.tableHtml(nested, 0).isEmpty());
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(wrap(nested), 0), DictApiError);
    }

    void nestedSemanticTablesKeepOuterGridAndEmptyPaintedHeaders() {
        MainWindow window{QString()};
        QJsonArray outerCells;
        for (int i = 0; i < 4; ++i) {
            const QJsonObject emptyHeader{{QStringLiteral("header"), true}, {QStringLiteral("colspan"), 5},
                {QStringLiteral("background"), QStringLiteral("#800080")}, {QStringLiteral("spans"), QJsonArray{}}};
            QJsonArray cells;
            for (int j = 0; j < 4; ++j) cells.append(QJsonObject{{QStringLiteral("spans"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("target"), QStringLiteral("dog")},
                {QStringLiteral("text"), QStringLiteral("form %1 %2").arg(i).arg(j)}}}}});
            const QJsonObject child{{QStringLiteral("geometry"), QJsonObject{{QStringLiteral("border"), 1}, {QStringLiteral("cell_padding"), 2},
                {QStringLiteral("width"), QJsonObject{{QStringLiteral("unit"), QStringLiteral("percent")}, {QStringLiteral("value"), 100}}}}},
                {QStringLiteral("caption"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("target"), QStringLiteral("dog")},
                    {QStringLiteral("text"), QStringLiteral("child caption %1").arg(i)}}}},
                {QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{emptyHeader}}}, QJsonObject{{QStringLiteral("cells"), cells}}}}};
            outerCells.append(QJsonObject{{QStringLiteral("background"), QStringLiteral("#000000")}, {QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("nested_table"), child}});
        }
        const QJsonObject outer{{QStringLiteral("geometry"), QJsonObject{{QStringLiteral("border"), 0}, {QStringLiteral("cell_spacing"), 15}}},
            {QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), outerCells}}}}};
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            window.reading_->setHtml(window.tableHtml(outer, 0));
            auto *grid = qobject_cast<QTextTable *>(window.reading_->document()->rootFrame()->childFrames().first());
            QVERIFY(grid); QCOMPARE(grid->rows(), 1); QCOMPARE(grid->columns(), 4);
            QCOMPARE(grid->format().cellSpacing(), qreal(15));
            QCOMPARE(grid->childFrames().size(), 4);
            for (auto *frame : grid->childFrames()) {
                auto *child = qobject_cast<QTextTable *>(frame); QVERIFY(child);
                QCOMPARE(child->rows(), 2); QCOMPARE(child->columns(), 5);
                QCOMPARE(child->format().cellPadding(), qreal(2));
                QCOMPARE(child->cellAt(0, 0).columnSpan(), 5);
                QCOMPARE(child->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#800080")));
                QTextCursor empty = child->cellAt(0, 0).firstCursorPosition();
                QCOMPARE(empty.block().text(), QString());
                const auto form = window.reading_->document()->find(QStringLiteral("form 0 0"));
                QVERIFY(!form.isNull()); QVERIFY(form.charFormat().isAnchor());
                QCOMPARE(form.charFormat().anchorHref(), QStringLiteral("dict:dog"));
                QCOMPARE(form.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
                QCOMPARE(child->cellAt(1, 0).format().background().color(), QColor(QStringLiteral("#000000")));
                const auto caption = window.reading_->document()->find(QStringLiteral("child caption 0"));
                QVERIFY(!caption.isNull()); QCOMPARE(caption.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
                auto *accessible = QAccessible::queryAccessibleInterface(window.reading_); QVERIFY(accessible && accessible->textInterface());
                int start = -1, end = -1;
                const QString attributes = accessible->textInterface()->attributes(form.selectionStart(), &start, &end);
                QVERIFY(attributes.contains(QStringLiteral("background-color:rgb(0,0,0)")));
            }
        }
        QJsonObject missingSpacing = outer;
        QJsonObject geometry = outer.value(QStringLiteral("geometry")).toObject(); geometry.remove(QStringLiteral("cell_spacing"));
        missingSpacing.insert(QStringLiteral("geometry"), geometry);
        const QString absentHtml = window.tableHtml(missingSpacing, 0);
        geometry.insert(QStringLiteral("cell_spacing"), QJsonValue::Null); missingSpacing.insert(QStringLiteral("geometry"), geometry);
        QCOMPARE(window.tableHtml(missingSpacing, 0), absentHtml);
        geometry.insert(QStringLiteral("cell_spacing"), 0); missingSpacing.insert(QStringLiteral("geometry"), geometry);
        QVERIFY(window.tableHtml(missingSpacing, 0).contains(QStringLiteral("border-collapse:separate")));
        missingSpacing.insert(QStringLiteral("geometry"), QStringLiteral("invalid"));
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(missingSpacing, 0), DictApiError);
    }

    void typedColorSwatchRendersWithAccessibleTextAndKeepsFallback() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QJsonArray fallbackSpans{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Fallback link")}, {QStringLiteral("target"), QStringLiteral("yellow")}}};
        const QJsonObject cell{{QStringLiteral("spans"), fallbackSpans}};
        const QJsonObject row{{QStringLiteral("cells"), QJsonArray{cell}}};
        const QJsonObject table{{QStringLiteral("rows"), QJsonArray{row}}};
        const QJsonObject ordinary{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("depth"), 2},
            {QStringLiteral("table"), table}};
        const QString fallback = window.blockHtml(ordinary);
        const auto featured = [&](const QString &kind, const QJsonValue &data) {
            QJsonObject block = ordinary;
            block.insert(QStringLiteral("feature"), QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("data"), data}});
            return block;
        };
        for (const QJsonValue &invalid : {QJsonValue(QStringLiteral("#FFFF00")), QJsonValue(QStringLiteral("#ff0")),
                QJsonValue(QStringLiteral("#ffff00;")), QJsonValue(QStringLiteral("#gggggg")), QJsonValue(123), QJsonValue()})
            QCOMPARE(window.blockHtml(featured(QStringLiteral("color_swatch"), invalid)), fallback);
        QCOMPARE(window.blockHtml(featured(QStringLiteral("unknown"), QStringLiteral("#ffff00"))), fallback);
        for (const auto &extra : {qMakePair(QStringLiteral("language"), QStringLiteral("en")),
                qMakePair(QStringLiteral("tail_kind"), QStringLiteral("text")),
                qMakePair(QStringLiteral("tail"), QStringLiteral("retained semantic tail"))}) {
            QJsonObject block = featured(QStringLiteral("color_swatch"), QStringLiteral("#ffff00"));
            QJsonObject feature = block.value(QStringLiteral("feature")).toObject();
            feature.insert(extra.first, extra.second);
            block.insert(QStringLiteral("feature"), feature);
            QCOMPARE(window.blockHtml(block), fallback);
        }
        for (const QString &color : {QStringLiteral("#ffff00"), QStringLiteral("#000000"), QStringLiteral("#ffffff")}) {
            window.reading_->setHtml(window.blockHtml(featured(QStringLiteral("color_swatch"), color)));
            const QString label = QStringLiteral("Color sample ") + color;
            QCOMPARE(window.reading_->toPlainText().count(label), 1);
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Fallback link")));
            QTextTable *sample = nullptr;
            for (QTextFrame *frame : window.reading_->document()->rootFrame()->childFrames())
                if (auto *candidate = qobject_cast<QTextTable *>(frame)) { sample = candidate; break; }
            QVERIFY(sample);
            QCOMPARE(sample->cellAt(0, 0).format().background().color(), QColor(color));
            QCOMPARE(sample->format().leftMargin(), qreal(46));
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it)
                    QVERIFY(!it.fragment().charFormat().isAnchor());
        }
        window.resize(580, 480);
        window.show();
        window.reading_->setHtml(window.blockHtml(featured(QStringLiteral("color_swatch"), QStringLiteral("#ffff00"))));
        window.reading_->setFocus();
        QTRY_VERIFY(window.reading_->hasFocus());
        QTRY_VERIFY(textIsVisible(window.reading_, QStringLiteral("Color sample #ffff00")));
        const QImage rendered = window.reading_->viewport()->grab().toImage();
        int yellowPixels = 0;
        for (int y = 0; y < rendered.height(); ++y)
            for (int x = 0; x < rendered.width(); ++x)
                if (rendered.pixelColor(x, y) == QColor(QStringLiteral("#ffff00"))) ++yellowPixels;
        QVERIFY(yellowPixels >= 100);
        auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
        QVERIFY(accessible);
        auto *accessibleText = accessible->textInterface();
        QVERIFY(accessibleText);
        QCOMPARE(accessibleText->text(0, accessibleText->characterCount()).count(QStringLiteral("Color sample #ffff00")), 1);
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-color-swatch.png")));
        QTest::keyClick(window.reading_, Qt::Key_A, Qt::ControlModifier);
        QVERIFY(window.reading_->textCursor().selectedText().contains(QStringLiteral("Color sample #ffff00")));
        QTest::keyClick(window.reading_, Qt::Key_Tab);
        QTRY_VERIFY(QApplication::focusWidget() != nullptr && QApplication::focusWidget() != window.reading_);
    }

    void tableOwnedByListItemKeepsMarkerBesideFirstRow() {
        MainWindow window(fixture_, QStringLiteral("dog"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(640, 600); window.show();
        const auto px = [](int value) { return QJsonObject{{"unit", "px"}, {"value", value}}; };
        const auto text = [](const QString &value) { return QJsonObject{{"kind", "text"}, {"text", value}}; };
        QJsonObject heading{{"spans", QJsonArray{QJsonObject{{"kind", "link"}, {"text", "First row link"}, {"target", "cat"}}}}, {"header", true}, {"colspan", 2}};
        QJsonObject linked{{"spans", QJsonArray{QJsonObject{{"kind", "link"}, {"text", "Linked cell"}, {"target", "dog"}, {"bold", true}, {"underline", true}}}}, {"rowspan", 2}, {"background", "#ffc0cb"}};
        const QJsonArray rows{QJsonObject{{"cells", QJsonArray{heading}}},
            QJsonObject{{"cells", QJsonArray{linked, QJsonObject{{"spans", QJsonArray{text("Upper cell")}}}}}},
            QJsonObject{{"cells", QJsonArray{QJsonObject{{"spans", QJsonArray{text("Final cell")}}, {"background", "#d0ffd0"}}}}}};
        {
            // A normal native list ends before this independent semantic table.
            // Qt may still use its last text block as the table's predecessor.
            SemanticHtml::setHtml(window.reading_, QStringLiteral("<ol><li>Ordinary item</li></ol>")
                + window.tableHtml(QJsonObject{{"rows", rows}}, 0));
            auto *document = window.reading_->document();
            const QTextCursor item = document->find(QStringLiteral("Ordinary item"));
            const QTextCursor cell = document->find(QStringLiteral("First row link"));
            QVERIFY(!item.isNull() && !cell.isNull());
            QVERIFY(item.block().textList() && cell.currentTable());
            const QTextBlock before = document->findBlock(cell.currentTable()->firstPosition() - 1);
            QCOMPARE(before, item.block());
            QVERIFY(!before.blockFormat().hasProperty(SemanticHtml::tableListOwnerProperty));
            auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
            QVERIFY(accessible && accessible->textInterface());
            int start = -1, end = -1;
            const QString itemAttributes = accessible->textInterface()->attributes(item.selectionStart(), &start, &end);
            QVERIFY(itemAttributes.contains(QStringLiteral("xml-roles:listitem;")));
            QVERIFY(itemAttributes.contains(QStringLiteral("list-item-label:1.;")));
            const QString cellAttributes = accessible->textInterface()->attributes(cell.selectionStart(), &start, &end);
            QVERIFY(start <= cell.selectionStart() && cell.selectionStart() < end);
            QVERIFY(!cellAttributes.contains(QStringLiteral("xml-roles:listitem;")));
            QVERIFY(!cellAttributes.contains(QStringLiteral("list-item-label:")));
            QCOMPARE(cell.charFormat().anchorHref(), QStringLiteral("dict:cat"));
        }
        const QString prose = QStringLiteral("Following prose remains selectable and wraps around the actual floated table. ").repeated(10);
        const QJsonObject following{{"kind", "paragraph"}, {"spans", QJsonArray{text(prose)}}};
        const QJsonObject ordinary{{"kind", "list_item"}, {"depth", 2}, {"list_path", "##"}, {"number", "9"}, {"spans", QJsonArray{text("Plain sibling")}}};
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        int caseIndex = 0;
        for (const QString &label : {QString(), QStringLiteral("3.1")}) {
            for (const QString &placement : {QStringLiteral("auto"), QStringLiteral("fixed"), QStringLiteral("percent"), QStringLiteral("left"), QStringLiteral("right")}) {
                QJsonObject style{{"background", "#e9f3ff"}, {"collapse", "collapse"},
                    {"margins", QJsonObject{{"top", px(0)}, {"right", px(12)}, {"bottom", px(0)}, {"left", px(0)}}}};
                if (placement == QStringLiteral("left") || placement == QStringLiteral("right")) style.insert("float_side", placement);
                QJsonObject geometry{{"border", 1}, {"cell_padding", 4}, {"cell_spacing", 0}};
                if (placement != QStringLiteral("auto")) geometry.insert("width", QJsonObject{
                    {"unit", placement == QStringLiteral("percent") ? "percent" : "px"}, {"value", placement == QStringLiteral("percent") ? 55 : 240}});
                const QJsonObject table{{"rows", rows}, {"style", style}, {"geometry", geometry}};
                int resize = 0;
                for (const int width : {640, 480, 900, 640}) {
                    window.resize(width, 600);
                    QVector<QRectF> baselineGeometry;
                    QSize baselineViewport;
                    qreal baselineDocumentWidth = 0;
                    bool baselineScrollbar = false;
                    QTextBlockFormat baselineProseFormat;
                    QString baselineProseText;
                    QVector<QTextCharFormat> baselineProseCharacters;
                    QMap<int, QVariant> baselineFormat;
                    QString baselineText;
                    QString expectedOwnedText;
                    QString expectedOwnedAccessibleText;
                    int baselineAccessibleCount = -1;
                    QString precedingText;
                    QMap<int, QVariant> precedingFormat;
                    QRectF precedingGeometry;
                    QVector<QTextCharFormat> precedingCharacters;
                    int baselineTablePosition = -1;
                    bool insertedMarkerBlock = false;
                    QImage baselinePixels;
                    for (const bool owned : {false, true}) {
                        const QJsonObject source{{"kind", owned ? "list_item" : "table"}, {"depth", 2},
                            {"list_path", label.isEmpty() ? "**" : "##"}, {"number", label}, {"spans", QJsonArray{}}, {"table", table}};
                        QJsonObject continuation = source; continuation.insert("kind", "table"); continuation.insert("number", "");
                        const QJsonObject entry{{"title", "Table list marker"}, {"kind", "language"}, {"language", window.api_->language()},
                            {"sections", QJsonArray{QJsonObject{{"level", 2}, {"title", "Examples"}, {"blocks", QJsonArray{source, following, continuation, ordinary}}}}}};
                        const QByteArray response = QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson();
                        window.renderResponse(response, false);
                        QTRY_VERIFY(window.reading_->isVisible() && !window.readingFloatLayoutScheduled_);
                        const QString frame = QStringLiteral(".tmp/ui-screenshots/table-list-native-%1-%2-%3-%4.png")
                            .arg(caseIndex).arg(resize).arg(owned ? QStringLiteral("owned") : QStringLiteral("continuation")).arg(QCoreApplication::applicationPid());
                        QVERIFY(window.grab().save(frame));
                        const QImage pixels = window.reading_->viewport()->grab().toImage();
                        auto *document = window.reading_->document();
                        const QTextCursor firstLink = document->find("First row link");
                        const QTextCursor nextLink = document->find("First row link", firstLink.selectionEnd());
                        QTextTable *actual = firstLink.currentTable();
                        QTextTable *next = nextLink.currentTable();
                        QVERIFY(actual && next && actual != next);
                        QCOMPARE(actual->parentFrame(), document->rootFrame());
                        QCOMPARE(next->parentFrame(), document->rootFrame());
                        for (auto *item : {actual, next}) {
                            QCOMPARE(item->rows(), 3); QCOMPARE(item->columns(), 2);
                            QCOMPARE(item->cellAt(0, 0).columnSpan(), 2);
                            QCOMPARE(item->cellAt(1, 0).rowSpan(), 2);
                            QCOMPARE(item->cellAt(2, 0).firstPosition(), item->cellAt(1, 0).firstPosition());
                            QCOMPARE(item->cellAt(1, 0).format().background().color(), QColor("#ffc0cb"));
                            QCOMPARE(item->cellAt(2, 1).format().background().color(), QColor("#d0ffd0"));
                        }
                        QCOMPARE(actual->format().position(), placement == QStringLiteral("left") ? QTextFrameFormat::FloatLeft
                            : placement == QStringLiteral("right") ? QTextFrameFormat::FloatRight : QTextFrameFormat::InFlow);
                        auto format = actual->format().properties(); format.remove(QTextFormat::ObjectIndex);
                        QVector<QRectF> resolved{document->documentLayout()->frameBoundingRect(actual), document->documentLayout()->frameBoundingRect(next)};
                        const QTextBlock paragraph = document->find("Following prose").block();
                        QVERIFY(paragraph.isValid());
                        QCOMPARE(paragraph.text().count(QStringLiteral("Following prose remains selectable and wraps around the actual floated table.")), 10);
                        const QSize viewportSize = window.reading_->viewport()->size();
                        const qreal documentWidth = document->textWidth();
                        const bool scrollbar = window.reading_->verticalScrollBar()->isVisible();
                        qInfo() << "table-list viewport" << placement << width << owned
                            << viewportSize << documentWidth << "vertical-scrollbar" << scrollbar;
                        QCOMPARE(window.reading_->horizontalScrollBar()->maximum(), 0);
                        QVector<QTextCharFormat> proseCharacters;
                        for (int i = 0; i < paragraph.text().size(); ++i) {
                            QTextCursor character(document); character.setPosition(paragraph.position() + i);
                            character.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
                            proseCharacters.append(character.charFormat());
                        }
                        const QPointF origin = document->documentLayout()->blockBoundingRect(paragraph).topLeft();
                        bool beside = false, below = false;
                        int covered = 0;
                        qreal previousBottom = -1;
                        for (int i = 0; i < paragraph.layout()->lineCount(); ++i) {
                            const QTextLine line = paragraph.layout()->lineAt(i);
                            QCOMPARE(line.textStart(), covered);
                            QVERIFY(line.textLength() > 0);
                            covered += line.textLength();
                            const QRectF rect = line.naturalTextRect().translated(origin);
                            qInfo() << "table-list prose-line" << placement << width << owned << i
                                << line.textStart() << line.textLength() << rect
                                << paragraph.text().mid(line.textStart(), line.textLength());
                            QVERIFY(rect.top() >= previousBottom);
                            previousBottom = rect.bottom();
                            QVERIFY(rect.left() >= 0 && rect.right() <= documentWidth);
                            resolved.append(rect);
                            beside |= rect.top() < resolved[0].bottom() && rect.bottom() > resolved[0].top();
                            below |= rect.top() >= resolved[0].bottom();
                        }
                        QCOMPARE(covered, paragraph.text().size());
                        for (auto *item : {actual, next}) {
                            for (auto block = document->findBlock(item->firstPosition());
                                 block.isValid() && block.position() <= item->lastPosition(); block = block.next()) {
                                const QPointF cellOrigin = document->documentLayout()->blockBoundingRect(block).topLeft();
                                for (int line = 0; line < block.layout()->lineCount(); ++line) {
                                    const QRectF content = block.layout()->lineAt(line).naturalTextRect().translated(cellOrigin);
                                    for (int i = 2; i < resolved.size(); ++i)
                                        QVERIFY2(!content.intersects(resolved[i]), "prose overlaps table content");
                                }
                            }
                        }
                        if (placement == QStringLiteral("left") || placement == QStringLiteral("right")) { QVERIFY(beside); QVERIFY(below); }
                        QCOMPARE(window.currentEntry_, entry);
                        QCOMPARE(QJsonDocument::fromJson(window.currentJson_), QJsonDocument::fromJson(response));
                        const auto pointFor = [&](QTextCursor selection) {
                            QTextCursor end(selection); selection.setPosition(selection.selectionStart()); end.setPosition(end.selectionEnd());
                            return window.reading_->cursorRect(selection).united(window.reading_->cursorRect(end)).center();
                        };
                        for (const auto &pair : {qMakePair(firstLink, QStringLiteral("dict:cat")), qMakePair(document->find("Linked cell"), QStringLiteral("dict:dog"))}) {
                            const QPoint point = pointFor(pair.first);
                            QCOMPARE(window.reading_->anchorAt(point), pair.second);
                            const QPoint documentPoint = point + QPoint(window.reading_->horizontalScrollBar()->value(), window.reading_->verticalScrollBar()->value());
                            const int offset = document->documentLayout()->hitTest(documentPoint, Qt::ExactHit);
                            QVERIFY(offset >= pair.first.selectionStart() && offset < pair.first.selectionEnd());
                        }
                        const QTextBlock before = document->findBlock(actual->firstPosition() - 1);
                        const QTextBlock beforeNext = document->findBlock(next->firstPosition() - 1);
                        qInfo().noquote() << "table-list boundary" << placement << width << owned
                            << "frame" << actual->firstPosition() << actual->lastPosition()
                            << "preceding-block" << before.position() << before.length() << before.text();
                        QVERIFY(!beforeNext.textList());
                        if (!owned) {
                            QVERIFY(!before.textList()); baselineGeometry = resolved; baselineFormat = format;
                            baselineViewport = viewportSize; baselineDocumentWidth = documentWidth;
                            baselineScrollbar = scrollbar; baselineProseFormat = paragraph.blockFormat();
                            baselineProseText = paragraph.text();
                            baselineProseCharacters = proseCharacters;
                            baselineText = document->toPlainText(); baselinePixels = pixels;
                            precedingText = before.text(); precedingFormat = before.blockFormat().properties();
                            precedingGeometry = document->documentLayout()->blockBoundingRect(before);
                            for (int i = 0; i < before.text().size(); ++i) {
                                QTextCursor character(document); character.setPosition(before.position() + i);
                                character.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
                                precedingCharacters.append(character.charFormat());
                            }
                            baselineTablePosition = actual->firstPosition();
                            insertedMarkerBlock = !before.text().isEmpty();
                            expectedOwnedText = baselineText;
                            auto *baselineAccessible = QAccessible::queryAccessibleInterface(window.reading_);
                            QVERIFY(baselineAccessible && baselineAccessible->textInterface());
                            auto *baselineAx = baselineAccessible->textInterface();
                            baselineAccessibleCount = baselineAx->characterCount();
                            expectedOwnedAccessibleText = baselineAx->text(0, baselineAccessibleCount);
                            QCOMPARE(expectedOwnedAccessibleText.size(), baselineAccessibleCount);
                            QCOMPARE(baselineAccessible->text(QAccessible::Value), baselineText);
                            // The native list owns one empty structural block,
                            // never the preceding authored heading/prose.
                            if (!before.text().isEmpty()) {
                                expectedOwnedText.insert(actual->firstPosition() - 1, QChar('\n'));
                                expectedOwnedAccessibleText.insert(actual->firstPosition() - 1, QChar('\n'));
                            }
                        } else {
                            QCOMPARE(format, baselineFormat);
                            QCOMPARE(paragraph.blockFormat(), baselineProseFormat);
                            QCOMPARE(paragraph.text(), baselineProseText);
                            QCOMPARE(proseCharacters, baselineProseCharacters);
                            const bool floated = placement == QStringLiteral("left") || placement == QStringLiteral("right");
                            if (floated) {
                                const qreal advance = resolved[0].top() - baselineGeometry[0].top();
                                const QRectF markerLine = document->documentLayout()->blockBoundingRect(before);
                                QVERIFY(advance > 0);
                                QCOMPARE(advance, markerLine.height());
                                QCOMPARE(before.layout()->lineCount(), 1);
                                const qreal widthChange = documentWidth - baselineDocumentWidth;
                                QCOMPARE(widthChange, qreal(viewportSize.width() - baselineViewport.width()));
                                QCOMPARE(viewportSize.height(), baselineViewport.height());
                                if (widthChange != 0) {
                                    // The extra native line can introduce a scrollbar.
                                    // Its narrower viewport legitimately changes word breaks.
                                    QVERIFY(!baselineScrollbar && scrollbar);
                                    QCOMPARE(widthChange, -qreal(window.reading_->verticalScrollBar()->width()));
                                }
                                for (int i = 0; i < 2; ++i) {
                                    QCOMPARE(resolved[i].size(), baselineGeometry[i].size());
                                    QCOMPARE(resolved[i].left(), baselineGeometry[i].left()
                                        + (placement == QStringLiteral("right") ? widthChange : 0));
                                }
                                QCOMPARE(resolved[1].top() - resolved.last().bottom(),
                                    baselineGeometry[1].top() - baselineGeometry.last().bottom());
                                if (widthChange == 0) {
                                    QCOMPARE(resolved.size(), baselineGeometry.size());
                                    for (int i = 0; i < resolved.size(); ++i)
                                        QCOMPARE(resolved[i], baselineGeometry[i].translated(0, advance));
                                }
                            } else {
                                QCOMPARE(resolved, baselineGeometry);
                            }
                            QCOMPARE(document->toPlainText(), expectedOwnedText);
                            QCOMPARE(actual->firstPosition(), baselineTablePosition + int(insertedMarkerBlock));
                            if (insertedMarkerBlock) {
                                QCOMPARE(before.previous().text(), precedingText);
                                auto expectedPrecedingFormat = precedingFormat;
                                if (expectedPrecedingFormat.value(QTextFormat::BlockBottomMargin).toDouble() > 0)
                                    expectedPrecedingFormat[QTextFormat::BlockBottomMargin] = qreal(0);
                                QCOMPARE(before.previous().blockFormat().properties(), expectedPrecedingFormat);
                                QRectF expectedHeading = precedingGeometry;
                                expectedHeading.setWidth(expectedHeading.width() + documentWidth - baselineDocumentWidth);
                                QCOMPARE(document->documentLayout()->blockBoundingRect(before.previous()), expectedHeading);
                                QVector<QTextCharFormat> characters;
                                for (int i = 0; i < before.previous().text().size(); ++i) {
                                    QTextCursor character(document); character.setPosition(before.previous().position() + i);
                                    character.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
                                    characters.append(character.charFormat());
                                }
                                QCOMPARE(characters, precedingCharacters);
                                QVERIFY(!before.previous().textList());
                            }
                            QVERIFY(before.text().isEmpty()); QVERIFY(before.textList()); QCOMPARE(before.textList()->count(), 1);
                            QVERIFY(before.blockFormat().hasProperty(SemanticHtml::tableListOwnerProperty));
                            QCOMPARE(before.blockFormat().intProperty(SemanticHtml::tableListOwnerProperty), actual->objectIndex());
                            QCOMPARE(before.length(), 1); QCOMPARE(actual->firstPosition(), before.position() + 1);
                            QCOMPARE(before.textList()->format().indent(), 2);
                            if (label.isEmpty()) QCOMPARE(before.textList()->format().style(), QTextListFormat::ListDisc);
                            else QCOMPARE(before.textList()->itemText(before), label + QChar('.'));
                            if (!floated) QCOMPARE(pixels.size(), baselinePixels.size());
                            QImage markerlessPixels = baselinePixels;
                            if (floated) {
                                // Isolate native marker ink without removing its
                                // normal line advance or changing the table flow.
                                QTextCursor markerCursor(before);
                                const QTextCharFormat original = markerCursor.blockCharFormat();
                                {
                                    auto restore = qScopeGuard([&] { markerCursor.setBlockCharFormat(original); });
                                    QTextCharFormat transparent = original;
                                    transparent.setForeground(QColor(Qt::transparent));
                                    markerCursor.setBlockCharFormat(transparent);
                                    markerlessPixels = window.reading_->viewport()->grab().toImage();
                                }
                                QCOMPARE(before.charFormat(), original);
                                QCOMPARE(document->documentLayout()->frameBoundingRect(actual), resolved[0]);
                                QCOMPARE(document->toPlainText(), expectedOwnedText);
                            }
                            QCOMPARE(markerlessPixels.size(), pixels.size());
                            QRect changed;
                            for (int y = 0; y < pixels.height(); ++y) for (int x = 0; x < pixels.width(); ++x)
                                if (pixels.pixel(x, y) != markerlessPixels.pixel(x, y)) changed = changed.united(QRect(x, y, 1, 1));
                            QVERIFY2(!changed.isEmpty(), "native list has no visible marker");
                            const qreal ratio = pixels.devicePixelRatio();
                            const QRectF markerBox(changed.x() / ratio, changed.y() / ratio, changed.width() / ratio, changed.height() / ratio);
                            QTextCursor linkStart(firstLink), linkEnd(firstLink);
                            linkStart.setPosition(firstLink.selectionStart()); linkEnd.setPosition(firstLink.selectionEnd());
                            const QRect firstRow = window.reading_->cursorRect(linkStart).united(window.reading_->cursorRect(linkEnd));
                            if (floated) {
                                QVERIFY2(markerBox.bottom() < firstRow.top(), "floated table must follow the normal marker line");
                            } else {
                                QVERIFY2(markerBox.right() < firstRow.left(), "marker overlaps the first row");
                                QVERIFY2(markerBox.bottom() >= firstRow.top() - 6 && markerBox.top() <= firstRow.bottom() + 6, "native marker is detached from first row");
                            }
                            const QRectF markerDocumentBox = markerBox.translated(window.reading_->horizontalScrollBar()->value(), window.reading_->verticalScrollBar()->value());
                            for (int i = 2; i < resolved.size(); ++i)
                                QVERIFY2(!markerDocumentBox.intersects(resolved[i]), "native marker overlaps following prose");
                            QVERIFY(window.reading_->viewport()->rect().contains(markerBox.toAlignedRect()));
                            auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
                            QVERIFY(accessible && accessible->textInterface());
                            auto *ax = accessible->textInterface();
                            // Native Qt text ranges retain table-boundary characters
                            // for offsets; Value is the separate visible plain text.
                            QCOMPARE(ax->characterCount(), baselineAccessibleCount + int(insertedMarkerBlock));
                            QCOMPARE(ax->text(0, ax->characterCount()), expectedOwnedAccessibleText);
                            QCOMPARE(accessible->text(QAccessible::Value), expectedOwnedText);
                            int attributeStart = -1, attributeEnd = -1;
                            const QString firstAttributes = ax->attributes(firstLink.selectionStart(), &attributeStart, &attributeEnd);
                            QVERIFY(firstAttributes.contains(QStringLiteral("xml-roles:listitem;")));
                            QVERIFY(firstAttributes.contains(QStringLiteral("level:2;")));
                            QVERIFY(firstAttributes.contains(QStringLiteral("list-item-label:%1;").arg(label.isEmpty() ? QStringLiteral("•") : label + QChar('.'))));
                            QVERIFY(attributeStart <= firstLink.selectionStart() && attributeEnd > firstLink.selectionStart());
                            QVERIFY(!ax->attributes(nextLink.selectionStart(), &attributeStart, &attributeEnd).contains(QStringLiteral("xml-roles:listitem;")));
                            const QRect firstRect = ax->characterRect(firstLink.selectionStart());
                            QVERIFY(firstRect.isValid());
                            const int axOffset = ax->offsetAtPoint(firstRect.center());
                            QVERIFY(axOffset >= firstLink.selectionStart() && axOffset < firstLink.selectionEnd());
                            QTextCursor selection(document); selection.select(QTextCursor::Document);
                            window.reading_->setTextCursor(selection); window.reading_->copy();
                            QCOMPARE(QApplication::clipboard()->text(), expectedOwnedText);
                            const QString copied = QApplication::clipboard()->mimeData()->html();
                            QVERIFY(copied.contains(label.isEmpty() ? QStringLiteral("<ul") : QStringLiteral("<ol")));
                            QTextDocument copiedDocument; SemanticHtml::setHtml(&copiedDocument, copied);
                            QCOMPARE(copiedDocument.toPlainText(), expectedOwnedText);
                            bool copiedList = false;
                            for (QTextBlock b = copiedDocument.begin(); b.isValid(); b = b.next()) if (b.textList()) {
                                copiedList = true;
                                if (label.isEmpty()) QCOMPARE(b.textList()->format().style(), QTextListFormat::ListDisc);
                                else QCOMPARE(b.textList()->itemText(b), label + QChar('.'));
                            }
                            QVERIFY(copiedList);
                            window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
                            QTest::keyClick(window.reading_, Qt::Key_Home, Qt::ControlModifier);
                            for (int step = 0; step < 8 && window.reading_->textCursor().charFormat().anchorHref() != QStringLiteral("dict:cat"); ++step)
                                QTest::keyClick(window.reading_, Qt::Key_Tab);
                            QCOMPARE(window.reading_->textCursor().charFormat().anchorHref(), QStringLiteral("dict:cat"));
                        }
                    }
                    ++resize;
                }
                ++caseIndex;
            }
        }
        const QJsonObject simpleTable{{"rows", QJsonArray{QJsonObject{{"cells", QJsonArray{QJsonObject{{"spans", QJsonArray{text("Counter cell")}}}}}}}}};
        for (const QJsonArray &emptyRows : {QJsonArray{}, QJsonArray{QJsonObject{{"cells", QJsonArray{}}}}}) {
            const QJsonObject empty{{"rows", emptyRows}, {"caption", QJsonArray{text("Empty caption")}}};
            QTextDocument document;
            const QJsonObject source{{"kind", "list_item"}, {"depth", 1}, {"number", "7"}, {"table", empty}};
            SemanticHtml::setHtml(&document, window.blockHtml(source));
            QCOMPARE(document.toPlainText().count(QStringLiteral("7.")), 1);
            QCOMPARE(document.toPlainText().count(QStringLiteral("Empty caption")), 1);
            QVERIFY(document.rootFrame()->childFrames().isEmpty());
            QJsonObject continuation = source; continuation.insert("kind", "table");
            SemanticHtml::setHtml(&document, window.blockHtml(continuation));
            QVERIFY(!document.toPlainText().contains(QStringLiteral("7.")));
            QCOMPARE(document.toPlainText().count(QStringLiteral("Empty caption")), 1);
        }
        for (const QString &label : {QStringLiteral("7"), QStringLiteral("0"), QStringLiteral("-2"), QStringLiteral("2147483647"), QStringLiteral("AA"), QStringLiteral("iii"), QStringLiteral("xxvi"), QStringLiteral("<i>")}) {
            QTextDocument document;
            const QJsonObject source{{"kind", "list_item"}, {"depth", 1}, {"number", label}, {"table", simpleTable}};
            SemanticHtml::setHtml(&document, window.blockHtml(source));
            auto *table = document.find("Counter cell").currentTable(); QVERIFY(table);
            const QTextBlock before = document.findBlock(table->firstPosition() - 1);
            QVERIFY(before.textList()); QCOMPARE(before.textList()->itemText(before), label + QChar('.'));
        }
        const QTextCursor first = window.reading_->document()->find("First row link");
        QTextCursor firstEnd(first), firstStart(first); firstStart.setPosition(first.selectionStart()); firstEnd.setPosition(first.selectionEnd());
        QSignalSpy clicked(window.reading_, &QTextBrowser::anchorClicked);
        QTest::mouseClick(window.reading_->viewport(), Qt::LeftButton, Qt::NoModifier,
            window.reading_->cursorRect(firstStart).united(window.reading_->cursorRect(firstEnd)).center());
        QCOMPARE(clicked.count(), 1); QCOMPARE(clicked.takeFirst().at(0).toUrl(), QUrl("dict:cat"));
        QTRY_COMPARE(window.currentEntry_.value(QStringLiteral("title")).toString(), QStringLiteral("cat"));
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

    void savedPreviewKeepsCapturedUnclassifiedBody() {
        MainWindow window{QString()};
        const auto paragraph = [](const QString &text) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}}};
        };
        const auto item = [](const QString &text) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("list_item")}, {QStringLiteral("depth"), 2},
                {QStringLiteral("list_path"), QStringLiteral(":#")}, {QStringLiteral("number"), QStringLiteral("1")},
                {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                    {QStringLiteral("text"), text}, {QStringLiteral("target"), text.trimmed()}}}}};
        };
        const auto section = [](int level, const QString &title, const QJsonArray &blocks) {
            return QJsonObject{{QStringLiteral("level"), level}, {QStringLiteral("title"), title}, {QStringLiteral("blocks"), blocks}};
        };
        // Body shapes from authenticated AS capture02 entries01 (father) and00 (assamese).
        const QJsonObject father{{QStringLiteral("title"), QStringLiteral("father")}, {QStringLiteral("sections"), QJsonArray{
            section(1, QStringLiteral("ইংৰাজী"), {}),
            section(2, QStringLiteral("নাম"), QJsonArray{paragraph(QStringLiteral("father")), item(QStringLiteral("জনক"))})}}};
        const QJsonObject assamese{{QStringLiteral("title"), QStringLiteral("assamese")}, {QStringLiteral("sections"), QJsonArray{
            section(2, QStringLiteral("Unclassified"), QJsonArray{paragraph(QStringLiteral("ইংৰাজী"))}),
            section(2, QStringLiteral("নাম"), QJsonArray{paragraph(QStringLiteral("assamese")), item(QStringLiteral("অসমীয়া "))}),
            section(2, QStringLiteral("বিশেষণ"), QJsonArray{paragraph(QStringLiteral("assamese")), item(QStringLiteral("অসমীয়া "))})}}};
        for (const QJsonObject &entry : {father, assamese}) {
            const QJsonObject original = entry;
            const QString expected = entry.value(QStringLiteral("title")).toString() == QStringLiteral("father")
                ? QStringLiteral("father · জনক") : QStringLiteral("ইংৰাজী · assamese · অসমীয়া · assamese · অসমীয়া");
            QCOMPARE(window.clueFor(entry), expected);
            QCOMPARE(window.savedWord(entry).clue, expected);
            QCOMPARE(entry, original);
            for (const auto &sectionValue : entry.value(QStringLiteral("sections")).toArray())
                for (const auto &blockValue : sectionValue.toObject().value(QStringLiteral("blocks")).toArray())
                    QVERIFY(blockValue.toObject().value(QStringLiteral("kind")).toString() != QStringLiteral("definition"));
        }
    }

    void savedPreviewOmitsOnlyRenderedHeadingCompanions() {
        MainWindow window{QString()};
        const auto block = [](const QString &kind, const QString &text, bool bold = false) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("level"), 2},
                {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                    {QStringLiteral("text"), text}, {QStringLiteral("bold"), bold}}}}};
        };
        const QJsonObject entry{{QStringLiteral("sections"), QJsonArray{QJsonObject{
            {QStringLiteral("level"), 2}, {QStringLiteral("title"), QStringLiteral("নাম")},
            {QStringLiteral("blocks"), QJsonArray{block(QStringLiteral("heading"), QStringLiteral("নাম"), true),
                block(QStringLiteral("paragraph"), QStringLiteral("headword")),
                block(QStringLiteral("heading"), QStringLiteral("Body heading")),
                block(QStringLiteral("list_item"), QStringLiteral("body text"))}}}}}};
        const QJsonObject original = entry;
        QCOMPARE(window.clueFor(entry), QStringLiteral("headword · Body heading · body text"));
        QCOMPARE(entry, original);
    }

    void savedPreviewBoundsUnclassifiedBodyWithoutSplittingCharacters() {
        MainWindow window{QString()};
        const auto entry = [](const QStringList &texts) {
            QJsonArray blocks;
            for (const QString &text : texts) blocks.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}}});
            return QJsonObject{{QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("blocks"), blocks}}}}};
        };
        const QString supplementary = QString::fromUtf8("\xf0\x9f\x98\x80");
        QCOMPARE(window.clueFor(entry({QString(410, QChar('a')), QStringLiteral("123456") + supplementary + QStringLiteral("tail")})),
            QString(410, QChar('a')) + QStringLiteral(" · 123456"));
        QCOMPARE(window.clueFor(entry({QString(419, QChar('a')) + supplementary, QStringLiteral("later")})), QString(419, QChar('a')));
        QCOMPARE(window.clueFor(entry({QString(418, QChar('a')), QStringLiteral("next")})), QString(418, QChar('a')));
        QCOMPARE(window.clueFor(entry({QString(500, QChar('a'))})), QString(420, QChar('a')));
    }

    void savedPreviewBoundsDefinitionsWithoutSplittingCharacters() {
        MainWindow window{QString()};
        const auto block = [](const QString &kind, const QString &text) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("spans"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}}};
        };
        const QString supplementary = QString::fromUtf8("\xf0\x9f\x98\x80");
        for (int prefixLength : {418, 419, 420}) {
            const QString prefix(prefixLength, QChar('a'));
            const QJsonObject entry{{QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("blocks"), QJsonArray{
                block(QStringLiteral("paragraph"), QStringLiteral("Fallback body")),
                block(QStringLiteral("definition"), QStringLiteral(" ")),
                block(QStringLiteral("definition"), prefix + supplementary + QStringLiteral("tail")),
                block(QStringLiteral("definition"), QStringLiteral("Later definition"))}}}}}};
            const QJsonObject original = entry;
            const QString expected = prefixLength == 418 ? prefix + supplementary : prefix;
            QCOMPARE(window.clueFor(entry), expected);
            QCOMPARE(window.savedWord(entry).clue, expected);
            QVERIFY(expected.size() <= 420);
            QCOMPARE(entry, original);
        }
    }

    void savedListsRemoveSelectedWordInsteadOfCurrent_data() {
        QTest::addColumn<bool>("bookmarks");
        QTest::addColumn<bool>("staleCurrent");
        QTest::newRow("history-null-current") << false << false;
        QTest::newRow("history-stale-current") << false << true;
        QTest::newRow("saved-null-current") << true << false;
        QTest::newRow("saved-stale-current") << true << true;
    }

    void savedListsRemoveSelectedWordInsteadOfCurrent() {
        QFETCH(bool, bookmarks);
        QFETCH(bool, staleCurrent);
        MainWindow window{QString()};
        for (const QString &key : {QStringLiteral("first"), QStringLiteral("second")}) {
            SavedWord word;
            word.key = key;
            word.title = key;
            word.language = QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QStringLiteral("Saved meaning for %1").arg(key);
            word.originRoot = QStringLiteral("/saved-fixture/%1").arg(key);
            word.originEdition = QStringLiteral("enwiktionary-20261001");
            if (bookmarks) window.learning_.toggleBookmark(word);
            else window.learning_.record(word);
        }
        const int tab = bookmarks ? 1 : 0;
        const QString emptyText = bookmarks ? QStringLiteral("No bookmarks yet.") : QStringLiteral("No history yet.");
        const QString removeText = bookmarks ? QStringLiteral("Remove selected bookmark") : QStringLiteral("Remove selected word");
        auto words = [&]() { return bookmarks ? window.learning_.bookmarks() : window.learning_.history(); };
        bool emptyChecked = false;
        auto verifyEmpty = [&](QWidget *page, QListWidget *list, QPushButton *remove) {
            emptyChecked = false;
            QCOMPARE(list->count(), 0);
            QVERIFY(list->isHidden());
            auto *empty = page->findChild<QLabel *>(QStringLiteral("savedWordsEmpty"));
            QVERIFY(empty && empty->isVisible());
            QCOMPARE(empty->text(), emptyText);
            QCOMPARE(empty->textFormat(), Qt::PlainText);
            QCOMPARE(empty->textInteractionFlags(), Qt::NoTextInteraction);
            QCOMPARE(empty->focusPolicy(), Qt::NoFocus);
            auto *accessible = QAccessible::queryAccessibleInterface(empty);
            QVERIFY(accessible);
            QCOMPARE(accessible->role(), QAccessible::StaticText);
            QCOMPARE(accessible->text(QAccessible::Name), emptyText);
            QVERIFY(!accessible->state().focusable);
            QVERIFY(!accessible->state().selectable);
            QVERIFY(!accessible->state().selected);
            auto *actions = accessible->actionInterface();
            QVERIFY(!actions || actions->actionNames().isEmpty());
            QVERIFY(!remove->isEnabled());
            emptyChecked = true;
        };
        bool exercised = false;
        bool removalCompleted = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *page = tabs->widget(tab);
            auto *list = page->findChild<QListWidget *>();
            auto *remove = buttonWithText(page, removeText);
            QVERIFY(list && remove);
            QCOMPARE(list->count(), 2);
            const QString keepKey = list->item(0)->data(Qt::UserRole).toString();
            const QString selectedKey = list->item(1)->data(Qt::UserRole).toString();
            QVERIFY(keepKey != selectedKey);
            list->setCurrentRow(0);
            list->selectionModel()->setCurrentIndex(staleCurrent ? list->model()->index(0, 0) : QModelIndex(), QItemSelectionModel::NoUpdate);
            list->selectionModel()->select(list->model()->index(1, 0), QItemSelectionModel::ClearAndSelect);
            QCOMPARE(list->selectedItems().size(), 1);
            QCOMPARE(list->selectedItems().first()->data(Qt::UserRole).toString(), selectedKey);
            if (staleCurrent) QCOMPARE(list->currentItem()->data(Qt::UserRole).toString(), keepKey);
            else QVERIFY(!list->currentItem());
            QVERIFY(remove->isEnabled());
            QTest::mouseClick(remove, Qt::LeftButton);
            QCOMPARE(words().size(), 1);
            QCOMPARE(words().first().key, keepKey);
            QCOMPARE(words().first().originRoot, QStringLiteral("/saved-fixture/%1").arg(keepKey));

            // A current row without selection must never remove another saved word.
            list->setCurrentRow(0);
            list->clearSelection();
            QVERIFY(list->currentItem());
            QVERIFY(!remove->isEnabled());
            remove->click();
            QCOMPARE(words().size(), 1);
            list->selectionModel()->select(list->model()->index(0, 0), QItemSelectionModel::ClearAndSelect);
            QVERIFY(remove->isEnabled());
            QTest::mouseClick(remove, Qt::LeftButton);
            QVERIFY(words().isEmpty());
            verifyEmpty(page, list, remove);
            QVERIFY(emptyChecked);
            list->setCurrentRow(0);
            QVERIFY(!list->currentItem() && list->selectedItems().isEmpty());
            QVERIFY(!remove->isEnabled());
            remove->click();
            QVERIFY(words().isEmpty());
            QCOMPARE(list->count(), 0);
            removalCompleted = true;
        });
        window.showLearningDialog(tab);
        QVERIFY(exercised);
        // The baseline already recorded its single row failure in the modal callback.
        if (!removalCompleted) return;

        bool reopenedEmpty = false;
        QTimer::singleShot(0, &window, [&] {
            reopenedEmpty = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *list = tabs->widget(tab)->findChild<QListWidget *>();
            auto *remove = buttonWithText(tabs->widget(tab), removeText);
            QVERIFY(list && remove);
            verifyEmpty(tabs->widget(tab), list, remove);
            QVERIFY(emptyChecked);
            auto *buttons = dialog->findChild<QDialogButtonBox *>(QStringLiteral("learningDialogButtons"));
            QVERIFY(buttons);
            auto *closeButton = buttons->button(QDialogButtonBox::Close);
            QVERIFY(closeButton && closeButton->isEnabled() && closeButton->isVisible());
            tabs->tabBar()->setFocus(Qt::TabFocusReason);
            QTRY_VERIFY(tabs->tabBar()->hasFocus());
            for (int steps = 0; steps < 12 && !closeButton->hasFocus(); ++steps) {
                QWidget *focused = QApplication::focusWidget();
                QVERIFY(focused && (focused == dialog || dialog->isAncestorOf(focused)));
                QTest::keyClick(focused, Qt::Key_Tab);
            }
            QVERIFY(closeButton->hasFocus());
            QTest::keyClick(closeButton, Qt::Key_Return);
            QVERIFY(!dialog->isVisible());
        });
        window.showLearningDialog(tab);
        QVERIFY(reopenedEmpty);

        // Clear history uses the same empty view as removing its last row.
        if (!bookmarks && !staleCurrent) {
            SavedWord word;
            word.key = QStringLiteral("clear-history-fixture");
            word.title = QStringLiteral("clear-history-fixture");
            word.language = QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QStringLiteral("Saved meaning for the Clear history fixture");
            window.learning_.record(word);
            QCOMPARE(window.learning_.history().size(), 1);
            QCOMPARE(window.learning_.history().first().key, word.key);
            bool cleared = false;
            QTimer::singleShot(0, &window, [&] {
                const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
                auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
                QVERIFY(dialog);
                auto *tabs = dialog->findChild<QTabWidget *>();
                QVERIFY(tabs);
                auto *page = tabs->widget(0);
                auto *list = page->findChild<QListWidget *>();
                auto *remove = buttonWithText(page, removeText);
                auto *clear = buttonWithText(page, QStringLiteral("Clear history"));
                QVERIFY(list && remove && clear && clear->isEnabled());
                QCOMPARE(list->count(), 1);
                bool confirmed = false;
                QTimer::singleShot(0, dialog, [&] {
                    QPointer<QMessageBox> question = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
                    const auto cancel = qScopeGuard([&] { if (question && !confirmed) question->reject(); });
                    QVERIFY(question);
                    QCOMPARE(question->windowTitle(), QStringLiteral("Clear history?"));
                    QVERIFY(question->defaultButton() == question->button(QMessageBox::No));
                    question->button(QMessageBox::Yes)->click();
                    confirmed = true;
                });
                QTest::mouseClick(clear, Qt::LeftButton);
                QVERIFY(confirmed);
                QVERIFY(window.learning_.history().isEmpty());
                verifyEmpty(page, list, remove);
                QVERIFY(emptyChecked);
                QVERIFY(!clear->isEnabled());
                cleared = true;
            });
            window.showLearningDialog(0);
            QVERIFY(cleared);
        }
    }

    void definitionQuizUsesDistinctVisibleTitles_data() {
        QTest::addColumn<bool>("hasOtherTitle");
        QTest::newRow("duplicate-owners-only") << false;
        QTest::newRow("duplicate-owners-and-other-title") << true;
    }

    void definitionQuizUsesDistinctVisibleTitles() {
        QFETCH(bool, hasOtherTitle);
        MainWindow window{QString()};
        QVector<SavedWord> expected;
        for (int index = 0; index < (hasOtherTitle ? 3 : 2); ++index) {
            SavedWord word;
            word.key = QStringLiteral("owner-key-%1").arg(index);
            word.title = index == 2 ? QStringLiteral("dog") : QStringLiteral("cat");
            word.language = index == 1 ? QStringLiteral("French") : QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QStringLiteral("Meaning from owner %1").arg(index);
            word.originRoot = QStringLiteral("/quiz-owner/%1").arg(index);
            word.originEdition = QStringLiteral("edition-%1").arg(index);
            expected.append(word);
            window.learning_.toggleBookmark(word);
        }
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        QCOMPARE(window.learningPool().size(), expected.size());
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            QVERIFY(games);
            QWidget *quiz = games->widget(0);
            auto *next = buttonWithText(quiz, QStringLiteral("Next"));
            QVERIFY(next);
            QVector<QPushButton *> choices;
            for (auto *button : quiz->findChildren<QPushButton *>()) if (button != next && button->isVisible()) choices.append(button);
            if (!hasOtherTitle) {
                QVERIFY(hasLabel(quiz, QStringLiteral("Open or bookmark at least two different words first.")));
                QVERIFY(choices.isEmpty());
                QVERIFY(!next->isEnabled());
                QCOMPARE(window.learning_.answerCount(), 0);
                return;
            }
            QCOMPARE(choices.size(), 2);
            QSet<QString> labels;
            for (auto *button : choices) { QVERIFY(button->isEnabled()); labels.insert(button->text()); }
            QCOMPARE(labels, (QSet<QString>{QStringLiteral("cat"), QStringLiteral("dog")}));
            // Randomness selects the real question; its displayed clue identifies the exact owner.
            const SavedWord *question = nullptr;
            for (const SavedWord &word : expected) if (hasLabel(quiz, word.clue)) question = &word;
            QVERIFY(question);
            auto *correct = buttonWithText(quiz, question->title);
            QVERIFY(correct);
            QTest::mouseClick(correct, Qt::LeftButton);
            QCOMPARE(window.learning_.answerCount(), 1);
            QCOMPARE(window.learning_.study().value(question->key).right, 1);
            for (const SavedWord &word : expected) {
                QCOMPARE(window.learning_.study().value(word.key).wrong, 0);
                if (word.key != question->key) QCOMPARE(window.learning_.study().value(word.key).right, 0);
            }
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
        QCOMPARE(window.learning_.bookmarks().size(), expected.size());
        for (const SavedWord &word : expected) {
            const auto saved = window.learning_.bookmarks();
            const auto it = std::find_if(saved.cbegin(), saved.cend(), [&](const SavedWord &value) { return value.key == word.key; });
            QVERIFY(it != saved.cend());
            QCOMPARE(it->originRoot, word.originRoot);
            QCOMPARE(it->originEdition, word.originEdition);
            QCOMPARE(it->language, word.language);
            QCOMPARE(it->title, word.title);
        }
    }

    void definitionQuizKeepsLiteralAmpersands() {
        MainWindow window{QString()};
        QVector<SavedWord> expected;
        for (const QString &title : {QStringLiteral("R&B"), QStringLiteral("RB")}) {
            SavedWord word;
            word.key = QStringLiteral("quiz-key-") + title;
            word.title = title;
            word.language = QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QStringLiteral("Meaning for ") + title;
            word.originRoot = QStringLiteral("/ampersand-fixture");
            word.originEdition = QStringLiteral("enwiktionary-20261001");
            expected.append(word);
            window.learning_.toggleBookmark(word);
        }
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            QVERIFY(games);
            QWidget *quiz = games->widget(0);
            auto *literal = buttonWithText(quiz, QStringLiteral("R&&B"));
            auto *plain = buttonWithText(quiz, QStringLiteral("RB"));
            QVERIFY(literal && plain);
            QVERIFY(literal->isVisible() && plain->isVisible());
            QVERIFY(QKeySequence::mnemonic(literal->text()).isEmpty());
            QVERIFY(QKeySequence::mnemonic(plain->text()).isEmpty());
            // Qt's real display-mnemonic parser must retain the literal ampersand glyph.
            const QFontMetrics metrics(literal->font());
            QCOMPARE(metrics.size(Qt::TextSingleLine | Qt::TextShowMnemonic, literal->text()).width(),
                     metrics.size(Qt::TextSingleLine, QStringLiteral("R&B")).width());
            QVERIFY(metrics.size(Qt::TextSingleLine, QStringLiteral("R&B")).width() >
                    metrics.size(Qt::TextSingleLine, QStringLiteral("RB")).width());
            const SavedWord *question = nullptr;
            for (const SavedWord &word : expected) if (hasLabel(quiz, word.clue)) question = &word;
            QVERIFY(question);
            auto *correct = question->title == QStringLiteral("R&B") ? literal : plain;
            QCOMPARE(correct->property("wordKey").toString(), question->key);
            QTest::mouseClick(correct, Qt::LeftButton);
            QCOMPARE(window.learning_.answerCount(), 1);
            QCOMPARE(window.learning_.study().value(question->key).right, 1);
            for (const SavedWord &word : expected) if (word.key != question->key)
                QCOMPARE(window.learning_.study().value(word.key).right, 0);
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
        QCOMPARE(window.learning_.bookmarks().size(), 2);
        QVERIFY(window.learning_.isBookmarked(QStringLiteral("quiz-key-R&B")));
        QVERIFY(window.learning_.isBookmarked(QStringLiteral("quiz-key-RB")));
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
            QVERIFY(hasLabel(games->widget(0), QStringLiteral("Open or bookmark at least two different words first.")));
            auto *quizNext = buttonWithText(games->widget(0), QStringLiteral("Next"));
            QVERIFY(quizNext && !quizNext->isEnabled());
            picker->setCurrentIndex(picker->findText(QStringLiteral("Flashcards")));
            QCOMPARE(picker->currentText(), QStringLiteral("Flashcards"));
            QCOMPARE(games->currentIndex(), 1);
            QStringList cardLabels;
            for (auto *label : games->currentWidget()->findChildren<QLabel *>()) cardLabels.append(label->text());
            QVERIFY2(hasLabel(games->currentWidget(), QStringLiteral("cat")), qPrintable(cardLabels.join(QStringLiteral(" | "))));
            QWidget *card = games->currentWidget();
            auto *reveal = buttonWithText(card, QStringLiteral("Reveal"));
            auto *again = buttonWithText(card, QStringLiteral("Again"));
            auto *gotIt = buttonWithText(card, QStringLiteral("Got it"));
            QVERIFY(reveal && again && gotIt);
            const SavedWord currentCard = window.learningPool().first();
            const auto studyBefore = window.learning_.study().value(currentCard.key);
            const int answersBefore = window.learning_.answerCount();
            const QByteArray bodyBefore = window.currentJson_;
            QVERIFY(reveal->isVisible() && reveal->isEnabled());
            QVERIFY(!again->isVisible() && !gotIt->isVisible());
            QVERIFY(hasLabel(card, QStringLiteral("Recall the definition, then reveal it.")));
            // Reach Reveal through real Tab navigation: a programmatic Tab focus
            // reason outside a Tab event does not establish Qt's keyboard cue.
            picker->setFocus(Qt::OtherFocusReason);
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(picker));
            for (int step = 0; step < 16 && QApplication::focusWidget() != reveal; ++step) {
                QWidget *focused = QApplication::focusWidget(); QVERIFY(focused);
                QTest::keyClick(focused, Qt::Key_Tab);
            }
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(reveal));
            QStyleOption revealFocus; revealFocus.initFrom(reveal);
            QVERIFY(revealFocus.state.testFlag(QStyle::State_KeyboardFocusChange));
            // Subsequent keys use the focus left by the action, without repair.
            QTest::keyClick(QApplication::focusWidget(), Qt::Key_Space);
            QVERIFY(hasLabel(card, currentCard.clue));
            QVERIFY(!reveal->isVisible() && again->isVisible() && gotIt->isVisible());
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(again));
            QStyleOption gradeFocus; gradeFocus.initFrom(again);
            QVERIFY(gradeFocus.state.testFlag(QStyle::State_KeyboardFocusChange));
            QCOMPARE(window.learning_.answerCount(), answersBefore);
            QTest::keyClick(QApplication::focusWidget(), Qt::Key_Space);
            QVERIFY(dialog->isVisible());
            QVERIFY(hasLabel(card, QStringLiteral("Recall the definition, then reveal it.")));
            QVERIFY(reveal->isVisible() && reveal->isEnabled());
            QVERIFY(!again->isVisible() && !gotIt->isVisible());
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(reveal));
            QCOMPARE(window.learning_.study().value(currentCard.key).wrong, studyBefore.wrong + 1);
            QCOMPARE(window.learning_.study().value(currentCard.key).right, studyBefore.right);
            QTest::keyClick(QApplication::focusWidget(), Qt::Key_Space);
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(again));
            QTest::keyClick(QApplication::focusWidget(), Qt::Key_Tab);
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(gotIt));
            QTest::keyClick(QApplication::focusWidget(), Qt::Key_Space);
            QVERIFY(dialog->isVisible());
            QVERIFY(hasLabel(card, QStringLiteral("Recall the definition, then reveal it.")));
            QVERIFY(reveal->isVisible() && reveal->isEnabled());
            QVERIFY(!again->isVisible() && !gotIt->isVisible());
            QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(reveal));
            QStyleOption nextFocus; nextFocus.initFrom(reveal);
            QVERIFY(nextFocus.state.testFlag(QStyle::State_KeyboardFocusChange));
            QCOMPARE(window.learning_.answerCount(), answersBefore + 2);
            QCOMPARE(window.learning_.study().value(currentCard.key).wrong, studyBefore.wrong + 1);
            QCOMPARE(window.learning_.study().value(currentCard.key).right, studyBefore.right + 1);
            QCOMPARE(window.currentJson_, bodyBefore);

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
            auto *inputAccessible = QAccessible::queryAccessibleInterface(input);
            QVERIFY(inputAccessible);
            QCOMPARE(inputAccessible->text(QAccessible::Name), QStringLiteral("Unscramble answer"));
            QTest::keyClicks(input, "dog");
            QCOMPARE(input->text(), QStringLiteral("dog"));
            QCOMPARE(inputAccessible->text(QAccessible::Name), QStringLiteral("Unscramble answer"));
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

    void scrambleAcceptsCanonicalAnswers_data() {
        QTest::addColumn<QString>("wordTitle");
        QTest::addColumn<QString>("answer");
        QTest::addColumn<bool>("correct");
        QTest::newRow("nfc-title-nfd-answer") << QStringLiteral("caf\u00e9") << QStringLiteral(" CAFE\u0301 ") << true;
        QTest::newRow("nfd-title-nfc-answer") << QStringLiteral("cafe\u0301") << QStringLiteral("CAF\u00c9") << true;
        QTest::newRow("missing-accent") << QStringLiteral("caf\u00e9") << QStringLiteral("cafe") << false;
        QTest::newRow("different-accent") << QStringLiteral("caf\u00e9") << QStringLiteral("caf\u00e8") << false;
        QTest::newRow("compatibility-not-canonical") << QStringLiteral("\uff43\uff41\uff46\uff45") << QStringLiteral("cafe") << false;
    }

    void scrambleAcceptsCanonicalAnswers() {
        QFETCH(QString, wordTitle);
        QFETCH(QString, answer);
        QFETCH(bool, correct);
        MainWindow window(fixture_, QStringLiteral("dog"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        SavedWord word = window.savedWord(window.currentEntry_);
        word.title = wordTitle;
        word.clue = QStringLiteral("Controlled canonical-equivalence practice word");
        window.learning_.toggleBookmark(word);
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            const auto close = qScopeGuard([&] { for (auto *dialog : window.findChildren<QDialog *>()) dialog->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            auto *picker = tabs->widget(2)->findChild<QComboBox *>();
            QVERIFY(games && picker);
            picker->setCurrentIndex(picker->findText(QStringLiteral("Unscramble")));
            QWidget *practice = games->currentWidget();
            auto *input = practice->findChild<QLineEdit *>();
            QVERIFY(input && input->isEnabled());
            input->setText(answer);
            QTest::keyClick(input, Qt::Key_Return);
            QVERIFY(hasLabel(practice, correct ? QStringLiteral("Correct.") : QStringLiteral("Answer: %1").arg(wordTitle)));
            QCOMPARE(window.learning_.answerCount(), 1);
            QCOMPARE(window.learning_.study().value(word.key).right, correct ? 1 : 0);
            QCOMPARE(window.learning_.study().value(word.key).wrong, correct ? 0 : 1);
            QCOMPARE(window.learning_.bookmarks().first().title, wordTitle);
            QCOMPARE(window.learning_.bookmarks().first().key, word.key);
            QCoreApplication::processEvents();
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-canonical-answer-%1.png").arg(QString::fromLatin1(QTest::currentDataTag()))));
            exercised = true;
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
    }

    void scrambleRequiresThreeGraphemes_data() {
        QTest::addColumn<QStringList>("clusters");
        QTest::newRow("one-combining") << QStringList{QStringLiteral("e\u0301\u0323")};
        QTest::newRow("two-combining") << QStringList{QStringLiteral("e\u0301"), QStringLiteral("t")};
        QTest::newRow("one-joined-emoji") << QStringList{QString::fromUtf8("\U0001f469\u200d\U0001f52c")};
        QTest::newRow("two-joined-emoji") << QStringList{QString::fromUtf8("\U0001f469\u200d\U0001f52c"), QStringLiteral("a")};
        QTest::newRow("three-combining") << QStringList{QStringLiteral("e\u0301"), QStringLiteral("a\u0308"), QStringLiteral("t")};
        QTest::newRow("three-joined-emoji") << QStringList{QString::fromUtf8("\U0001f469\u200d\U0001f52c"), QStringLiteral("a"), QStringLiteral("b")};
    }

    void scrambleRequiresThreeGraphemes() {
        QFETCH(QStringList, clusters);
        MainWindow window(fixture_, QStringLiteral("dog"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        SavedWord word = window.savedWord(window.currentEntry_);
        word.title = clusters.join(QString());
        word.clue = QStringLiteral("Controlled grapheme practice word");
        window.learning_.toggleBookmark(word);
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
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
            QWidget *practice = games->currentWidget();
            auto *input = practice->findChild<QLineEdit *>();
            auto *check = buttonWithText(practice, QStringLiteral("Check"));
            QVERIFY(input && check);
            const bool eligible = clusters.size() >= 3;
            QCOMPARE(input->isEnabled(), eligible);
            QCOMPARE(check->isEnabled(), eligible);
            if (!eligible) {
                QVERIFY(hasLabel(practice, QStringLiteral("No longer words yet")));
                QTest::keyClick(input, Qt::Key_Return);
                QCOMPARE(window.learning_.answerCount(), 0);
            } else {
                QStringList permutations;
                for (int first = 0; first < 3; ++first)
                    for (int second = 0; second < 3; ++second)
                        if (first != second) permutations.append(clusters[first] + clusters[second] + clusters[3 - first - second]);
                bool intactPrompt = false;
                for (auto *label : practice->findChildren<QLabel *>())
                    intactPrompt |= label->text() != word.title && permutations.contains(label->text());
                QVERIFY(intactPrompt);
            }
            QCoreApplication::processEvents();
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-scramble-%1.png").arg(QString::fromLatin1(QTest::currentDataTag()))));
            if (eligible) {
                input->setText(word.title);
                QTest::keyClick(input, Qt::Key_Return);
                QCOMPARE(window.learning_.study().value(word.key).right, 1);
            }
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


    void richSectionHeadingsKeepLexicalLinksFoldsAndNavigation() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.learning_.setCollapseEtymology(true);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        const auto span = [](const QString &text, const QString &target, const QString &kind = QStringLiteral("link"), const QString &trail = QString()) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text},
                {QStringLiteral("target"), target}, {QStringLiteral("trail"), trail}, {QStringLiteral("bold"), true}};
        };
        const auto block = [](const QString &kind, int depth, const QJsonArray &spans, int level = 0) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("depth"), depth}, {QStringLiteral("level"), level}, {QStringLiteral("spans"), spans}};
        };
        const auto section = [&](const QString &name, int level, const QJsonObject &heading, const QString &body) {
            return QJsonObject{{QStringLiteral("title"), name}, {QStringLiteral("level"), level},
                {QStringLiteral("blocks"), QJsonArray{block(QStringLiteral("heading"), 0, QJsonArray{heading}, level),
                    block(QStringLiteral("paragraph"), 0, QJsonArray{span(body, {}, QStringLiteral("text"))})}}};
        };
        entry.insert(QStringLiteral("sections"), QJsonArray{
            section(QStringLiteral("English"), 2, span(QStringLiteral("English"), QStringLiteral("#Usage_notes")), QStringLiteral("OWNER BODY")),
            section(QStringLiteral("Etymology 1"), 3, span(QStringLiteral("Etymology 1"), QStringLiteral("dog")), QStringLiteral("RICH HISTORICAL BODY")),
            section(QStringLiteral("Usage notes"), 3, span(QStringLiteral("Usage"), QStringLiteral("https://example.org/heading"), QStringLiteral("external_link"), QStringLiteral(" notes")), QStringLiteral("RICH USAGE BODY")),
            section(QStringLiteral("Noun"), 4, span(QStringLiteral("Noun"), QStringLiteral("cat")), QStringLiteral("FOLLOWING MEANING")),
            section(QStringLiteral("Same"), 3, span(QStringLiteral("Same"), QStringLiteral("same-a")), QStringLiteral("FIRST SAME BODY")),
            section(QStringLiteral("Same"), 3, span(QStringLiteral("Same"), QStringLiteral("same-b")), QStringLiteral("SECOND SAME BODY"))
        });
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        const auto render = [&] { window.renderResponse(QJsonDocument(response).toJson()); };
        render();
        const QString plain = window.reading_->toPlainText();
        for (const QString &name : {QStringLiteral("English"), QStringLiteral("Etymology 1"), QStringLiteral("Usage notes"), QStringLiteral("Noun")})
            QCOMPARE(plain.count(name), 1);
        QCOMPARE(plain.count(QStringLiteral("Same")), 2);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("English")).charFormat().anchorHref(), QStringLiteral("dict:%23Usage_notes"));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Usage notes")).charFormat().anchorHref(), QStringLiteral("https://example.org/heading"));
        QTextCursor same = window.reading_->document()->find(QStringLiteral("Same"), 0, QTextDocument::FindCaseSensitively);
        QVERIFY(!same.isNull());
        QCOMPARE(same.selectedText(), QStringLiteral("Same"));
        QCOMPARE(same.charFormat().anchorHref(), QStringLiteral("dict:same-a"));
        same = window.reading_->document()->find(QStringLiteral("Same"), same, QTextDocument::FindCaseSensitively);
        QVERIFY(!same.isNull());
        QCOMPARE(same.selectedText(), QStringLiteral("Same"));
        QCOMPARE(same.charFormat().anchorHref(), QStringLiteral("dict:same-b"));
        QVERIFY(window.sections_->findText(QStringLiteral("English")) >= 0);
        QCOMPARE(window.sections_->itemData(window.sections_->findText(QStringLiteral("Usage notes"))).toInt(), 2);
        for (int i = 0; i < 6; ++i) QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-%1").arg(i)));
        QVERIFY(window.collapsedSections_.contains(1));
        QVERIFY(!plain.contains(QStringLiteral("RICH HISTORICAL BODY")));
        QVERIFY(plain.contains(QStringLiteral("FOLLOWING MEANING")));

        // The rich heading keeps its lexical link; the separate disclosure is a
        // named native accessible button with the same keyboard activation path.
        window.resize(640, 600); window.activateWindow();
        QTRY_VERIFY(window.compactNavigation_);
        QWidget *readingSwitch = window.compactToolbar_->widgetForAction(window.readingPaneAction_);
        QVERIFY(readingSwitch);
        QTRY_VERIFY(readingSwitch->isVisible() && readingSwitch->isEnabled());
        QTest::mouseClick(readingSwitch, Qt::LeftButton);
        QTRY_VERIFY(window.reading_->isVisible());
        QTRY_VERIFY(window.reading_->hasFocus() && QApplication::focusWidget() == window.reading_);
        auto *readerAccessible = QAccessible::queryAccessibleInterface(window.reading_);
        QVERIFY(readerAccessible && readerAccessible->textInterface());
        QAccessibleInterface *disclosure = nullptr;
        QStringList disclosureNames;
        for (int i = 0; i < readerAccessible->childCount(); ++i) {
            auto *child = readerAccessible->child(i);
            if (!child || child->role() != QAccessible::Button) continue;
            QVERIFY(child->isValid());
            QCOMPARE(child->parent(), readerAccessible);
            QCOMPARE(readerAccessible->indexOfChild(child), i);
            disclosureNames.append(child->text(QAccessible::Name));
            if (child->text(QAccessible::Name) == QStringLiteral("Etymology 1")) {
                QVERIFY(!disclosure); disclosure = child;
            }
        }
        QCOMPARE(disclosureNames.size(), 6);
        QCOMPARE(disclosureNames.count(QStringLiteral("Same")), 2);
        QVERIFY(disclosure);
        const QAccessible::Id disclosureId = QAccessible::uniqueId(disclosure);
        const QPointer<QObject> disclosureObject(disclosure->object());
        // Establish a real focus transition rather than requesting focus on an
        // already-selected disclosure left behind by earlier navigation.
        window.reading_->setTextCursor(QTextCursor(window.reading_->document()));
        QVERIFY(window.bookmark_->isVisible() && window.bookmark_->isEnabled());
        window.bookmark_->setFocus(Qt::OtherFocusReason);
        QTRY_COMPARE(QApplication::focusWidget(), window.bookmark_);
        QVERIFY(!window.reading_->textCursor().hasSelection());
        QVERIFY(!disclosure->state().focused);
        struct DisclosureEvents {
            QPointer<QObject> reader, target;
            int stateChanges = 0, focusEvents = 0, reorders = 0;
            bool bothExpansionBits = true;
        } observedEvents{window.reading_, disclosureObject};
        static DisclosureEvents *observing = nullptr;
        QVERIFY(!observing);
        observing = &observedEvents;
        const bool wasAccessible = QAccessible::isActive();
        const auto previousHandler = QAccessible::installUpdateHandler([](QAccessibleEvent *event) {
            if (!observing) return;
            if (event->object() == observing->reader && event->type() == QAccessible::ObjectReorder)
                ++observing->reorders;
            if (event->object() != observing->target) return;
            if (event->type() == QAccessible::Focus) ++observing->focusEvents;
            if (event->type() == QAccessible::StateChanged) {
                ++observing->stateChanges;
                const auto fields = static_cast<QAccessibleStateChangeEvent *>(event)->changedStates();
                observing->bothExpansionBits &= fields.expanded && fields.collapsed;
            }
        });
        const auto restoreAccessibilityObserver = qScopeGuard([&] {
            QAccessible::installUpdateHandler(previousHandler);
            observing = nullptr;
            QAccessible::setActive(wasAccessible);
        });
        QAccessible::setActive(true);
        QVERIFY(QAccessible::isActive());
        auto *disclosureActions = disclosure->actionInterface();
        QVERIFY(disclosureActions);
        QVERIFY(disclosureActions->actionNames().contains(QAccessibleActionInterface::toggleAction()));
        QVERIFY(disclosureActions->actionNames().contains(QAccessibleActionInterface::pressAction()));
        QVERIFY(disclosureActions->actionNames().contains(QAccessibleActionInterface::setFocusAction()));
        QVERIFY(disclosure->state().expandable && disclosure->state().collapsed && !disclosure->state().expanded);
        const QString lexicalHref = window.reading_->document()->find(QStringLiteral("Etymology 1")).charFormat().anchorHref();
        const QByteArray entryJson = window.currentJson_;
        disclosureActions->doAction(QAccessibleActionInterface::setFocusAction());
        QTRY_VERIFY(disclosure->state().focused);
        QCOMPARE(readerAccessible->focusChild(), disclosure);
        QTRY_VERIFY(observedEvents.focusEvents > 0);
        const int focusBeforeReturn = observedEvents.focusEvents;
        window.bookmark_->setFocus(Qt::OtherFocusReason);
        QCOMPARE(QApplication::focusWidget(), window.bookmark_);
        QVERIFY(!disclosure->state().focused);
        // Return in the same event turn: the intervening real widget focus must
        // not be lost when queued disclosure notifications are coalesced.
        disclosureActions->doAction(QAccessibleActionInterface::setFocusAction());
        QVERIFY(disclosure->state().focused);
        QTRY_VERIFY(observedEvents.focusEvents > focusBeforeReturn);
        const int focusBeforeNoop = observedEvents.focusEvents;
        disclosureActions->doAction(QAccessibleActionInterface::setFocusAction());
        QCoreApplication::processEvents();
        QCOMPARE(observedEvents.focusEvents, focusBeforeNoop);
        const auto selectedHref = [&] {
            QTextCursor cursor = window.reading_->textCursor();
            if (!cursor.hasSelection()) return QString();
            cursor.setPosition(cursor.selectionStart());
            cursor.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            return cursor.charFormat().anchorHref();
        };
        QCOMPARE(selectedHref(), QStringLiteral("section:1"));
        const int focusBeforeTab = observedEvents.focusEvents;
        QVERIFY(window.reading_->isVisible() && QApplication::focusWidget() == window.reading_);
        QTest::keyClick(window.reading_, Qt::Key_Tab);
        QCOMPARE(selectedHref(), QStringLiteral("dict:dog"));
        QVERIFY(!disclosure->state().focused);
        QCoreApplication::processEvents();
        QCOMPARE(observedEvents.focusEvents, focusBeforeTab);
        QTest::keyClick(window.reading_, Qt::Key_Tab, Qt::ShiftModifier);
        QCOMPARE(selectedHref(), QStringLiteral("section:1"));
        QTRY_VERIFY(disclosure->state().focused);
        QTRY_VERIFY(observedEvents.focusEvents > focusBeforeTab);
        const QTextCursor exactDisclosure = window.reading_->textCursor();
        QTextCursor mixed = exactDisclosure;
        mixed.setPosition(exactDisclosure.selectionEnd() + 2, QTextCursor::KeepAnchor);
        window.reading_->setTextCursor(mixed);
        QVERIFY(!disclosure->state().focused);
        QVERIFY(readerAccessible->focusChild() != disclosure);
        disclosureActions->doAction(QAccessibleActionInterface::setFocusAction());
        QTRY_VERIFY(disclosure->state().focused);
        QCOMPARE(window.reading_->textCursor().selectionStart(), exactDisclosure.selectionStart());
        QCOMPARE(window.reading_->textCursor().selectionEnd(), exactDisclosure.selectionEnd());
        QVERIFY(window.collapsedSections_.contains(1));
        QVERIFY(disclosure->rect().isValid());
        QCOMPARE(readerAccessible->childAt(disclosure->rect().center().x(), disclosure->rect().center().y()), disclosure);
        const auto checkDisclosure = [&](bool expanded) {
            QCOMPARE(QAccessible::accessibleInterface(disclosureId), disclosure);
            QCOMPARE(disclosure->object(), disclosureObject.data());
            QCOMPARE(disclosure->text(QAccessible::Name), QStringLiteral("Etymology 1"));
            QCOMPARE(bool(disclosure->state().expanded), expanded);
            QCOMPARE(bool(disclosure->state().collapsed), !expanded);
            QVERIFY(disclosure->state().expandable && !disclosure->state().invisible);
            QCOMPARE(window.collapsedSections_.contains(1), !expanded);
            QCOMPARE(window.reading_->toPlainText().contains(QStringLiteral("RICH HISTORICAL BODY")), expanded);
            QCOMPARE(window.currentEntry_, entry);
            QCOMPARE(window.currentJson_, entryJson);
            QCOMPARE(window.reading_->document()->find(QStringLiteral("Etymology 1")).charFormat().anchorHref(), lexicalHref);
        };
        checkDisclosure(false);
        const int stateChangesBefore = observedEvents.stateChanges;
        disclosureActions->doAction(QAccessibleActionInterface::toggleAction());
        // A second synchronous composition must not discard the pending state event.
        window.refreshReading();
        QTRY_VERIFY(observedEvents.stateChanges > stateChangesBefore);
        QVERIFY(observedEvents.bothExpansionBits);
        checkDisclosure(true);
        disclosureActions->doAction(QAccessibleActionInterface::setFocusAction());
        QTRY_VERIFY(disclosure->state().focused);
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/rich-disclosure-accessible-%1-expanded.png")
            .arg(QCoreApplication::applicationPid())));
        disclosureActions->doAction(QAccessibleActionInterface::pressAction());
        QTRY_VERIFY(disclosure->state().focused);
        checkDisclosure(false);
        QCOMPARE(window.reading_->toPlainText(), plain);
        QVERIFY(window.reading_->isVisible() && QApplication::focusWidget() == window.reading_);
        QTest::keyClick(window.reading_, Qt::Key_Space);
        QTRY_VERIFY(disclosure->state().focused);
        checkDisclosure(true);
        QTest::keyClick(window.reading_, Qt::Key_Space);
        QTRY_VERIFY(disclosure->state().focused);
        checkDisclosure(false);
        QCOMPARE(window.reading_->toPlainText(), plain);
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/rich-disclosure-accessible-%1-collapsed.png")
            .arg(QCoreApplication::applicationPid())));

        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:1")));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("RICH HISTORICAL BODY")));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:1")));
        const QSet<int> retained = window.collapsedSections_;
        window.collapsedSections_.clear(); window.refreshReading();
        window.collapsedSections_ = retained; window.refreshReading();
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("RICH HISTORICAL BODY")));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Etymology 1")).charFormat().anchorHref(), QStringLiteral("dict:dog"));

        window.collapsedSections_.insert(2); window.refreshReading();
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23Usage_notes")));
        QVERIFY(!window.collapsedSections_.contains(0));
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("RICH USAGE BODY")));
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto clearHandler = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("https://example.org/heading")));
        QCOMPARE(receiver.opened, QList<QUrl>{QUrl(QStringLiteral("https://example.org/heading"))});
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:2")));
        QVERIFY(window.collapsedSections_.contains(2));
        const int pickerRow = window.sections_->findText(QStringLiteral("Usage notes"));
        window.sections_->setCurrentIndex(pickerRow);
        QVERIFY(QMetaObject::invokeMethod(window.sections_, "activated", Qt::DirectConnection, Q_ARG(int, pickerRow)));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("RICH USAGE BODY")));
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog")));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        const auto replacementEntry = window.currentEntry_;
        const auto replacementFolds = window.collapsedSections_;
        if (auto *stale = QAccessible::accessibleInterface(disclosureId)) {
            QVERIFY(!stale->isValid());
            stale->actionInterface()->doAction(QAccessibleActionInterface::toggleAction());
            QCOMPARE(window.currentEntry_, replacementEntry);
            QCOMPARE(window.collapsedSections_, replacementFolds);
        }
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        QVERIFY(disclosureObject.isNull());
        QVERIFY(!QAccessible::accessibleInterface(disclosureId));
        const int reorderBefore = observedEvents.reorders;
        QJsonObject withoutControls = window.currentEntry_;
        withoutControls.insert(QStringLiteral("sections"), QJsonArray{});
        QJsonObject noControlsResponse{{QStringLiteral("entries"), QJsonArray{withoutControls}}};
        window.renderResponse(QJsonDocument(noControlsResponse).toJson());
        window.refreshReading();
        QTRY_VERIFY(observedEvents.reorders > reorderBefore);
        for (int i = 0; i < readerAccessible->childCount(); ++i)
            QVERIFY(readerAccessible->child(i)->role() != QAccessible::Button);
    }

    void documentBoundaryKeysRevealCursorAfterSectionScroll() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(640, 600); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        const auto paragraph = [](const QString &text) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("depth"), 0},
                {QStringLiteral("spans"), QJsonArray{QJsonObject{
                    {QStringLiteral("kind"), QStringLiteral("text")},
                    {QStringLiteral("text"), text}}}}};
        };
        QJsonArray before;
        for (int i = 0; i < 32; ++i)
            before.append(paragraph(QStringLiteral("Boundary preface %1 with enough text to make the section destination scroll.").arg(i)));
        entry.insert(QStringLiteral("sections"), QJsonArray{
            QJsonObject{{QStringLiteral("title"), QStringLiteral("English")},
                {QStringLiteral("level"), 2}, {QStringLiteral("blocks"), before}},
            QJsonObject{{QStringLiteral("title"), QStringLiteral("Usage notes")},
                {QStringLiteral("level"), 3},
                {QStringLiteral("blocks"), QJsonArray{paragraph(QStringLiteral("Boundary destination."))}}}
        });
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        auto *browser = window.reading_;
        window.jumpToSection(1);
        QTRY_VERIFY(browser->hasFocus());
        QTRY_VERIFY(browser->verticalScrollBar()->value() > browser->verticalScrollBar()->minimum());
        // This is the observed normal section-jump state: viewport away from
        // the start while the text cursor is already at the start.
        QCOMPARE(browser->textCursor().position(), 0);
        QVERIFY(!browser->textCursor().hasSelection());
        QVERIFY(!browser->viewport()->rect().intersects(browser->cursorRect()));
        const QString originalText = browser->toPlainText();
        QTest::keyClick(browser, Qt::Key_Home, Qt::ControlModifier);
        QTRY_COMPARE(browser->verticalScrollBar()->value(), browser->verticalScrollBar()->minimum());
        QCOMPARE(browser->textCursor().position(), 0);
        QVERIFY(!browser->textCursor().hasSelection());
        QCOMPARE(browser->toPlainText(), originalText);

        // Match the installed read-only reader: Home followed by End, with
        // no test-only cursor repositioning to make the boundary check pass.
        QVERIFY(browser->verticalScrollBar()->maximum() > browser->verticalScrollBar()->minimum());
        QVERIFY(browser->textCursor().atStart());
        QTest::keyClick(browser, Qt::Key_End, Qt::ControlModifier);
        QTRY_COMPARE(browser->verticalScrollBar()->value(), browser->verticalScrollBar()->maximum());
        QCOMPARE(browser->toPlainText(), originalText);

        QTest::keyClick(browser, Qt::Key_Home, Qt::ControlModifier);
        QTRY_COMPARE(browser->verticalScrollBar()->value(), browser->verticalScrollBar()->minimum());
        QCOMPARE(browser->toPlainText(), originalText);

        // The equivalent document-end boundary must reveal an already-final
        // cursor without resetting selection or replacing Qt's key handling.
        QTextCursor ending(browser->document()); ending.movePosition(QTextCursor::End);
        browser->setTextCursor(ending);
        browser->verticalScrollBar()->setValue(browser->verticalScrollBar()->minimum());
        QTRY_COMPARE(browser->verticalScrollBar()->value(), browser->verticalScrollBar()->minimum());
        QVERIFY(browser->textCursor().atEnd());
        QVERIFY(!browser->viewport()->rect().intersects(browser->cursorRect()));
        QTest::keyClick(browser, Qt::Key_End, Qt::ControlModifier);
        QTRY_VERIFY(browser->verticalScrollBar()->value() > browser->verticalScrollBar()->minimum());
        QVERIFY(browser->viewport()->rect().intersects(browser->cursorRect()));
        QVERIFY(browser->textCursor().atEnd());
        QVERIFY(!browser->textCursor().hasSelection());
        QCOMPARE(browser->toPlainText(), originalText);
    }

    void tableTextAccessibilityGeometryMatchesVisibleCursor() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        browser->setHtml(QStringLiteral(
            "<p>RootProbe</p><p>Before line 0</p><p>Before line 1</p><p>Before line 2</p><p>Before line 3</p><p>Before line 4</p><p>Before line 5</p><p>Before line 6</p><p>Before line 7</p><p>Before line 8</p><p>Before line 9</p><p>Before line 10</p><p>Before line 11</p>"
            "<table border='1' cellpadding='18'><tr><td>Left cell</td><td>"
            "<p>Cell preface</p><table border='1' cellpadding='12'><tr><td>NestedProbe</td></tr></table>"
            "</td></tr></table><p>AfterProbe</p><p>After one</p><p>After two</p>"));
        QApplication::processEvents();
        auto *accessible = QAccessible::queryAccessibleInterface(browser);
        QVERIFY(accessible); auto *text = accessible->textInterface(); QVERIFY(text);
        QJsonArray observations;
        QList<bool> matches;
        const auto rectJson = [](const QRectF &rect) {
            return QJsonArray{rect.x(), rect.y(), rect.width(), rect.height()};
        };
        const auto observe = [&](const QString &label, bool scrollToTarget) {
            QTextCursor found = browser->document()->find(label);
            if (found.isNull()) return false;
            const int offset = found.selectionStart() + label.size() / 2;
            QTextCursor cursor(browser->document()); cursor.setPosition(offset);
            browser->setTextCursor(cursor);
            if (scrollToTarget) browser->ensureCursorVisible();
            else browser->verticalScrollBar()->setValue(0);
            QApplication::processEvents();
            const QRect local = browser->cursorRect(cursor);
            const QRect screen(browser->viewport()->mapToGlobal(local.topLeft()), local.size());
            const QRect reported = text->characterRect(offset);
            const bool sameText = text->text(offset, offset + 1) == QString(browser->document()->characterAt(offset));
            const bool intersects = reported.intersects(screen);
            const bool geometryRequired = scrollToTarget || label == QStringLiteral("RootProbe");
            const bool cursorVisible = browser->viewport()->rect().contains(local.center());
            const QTextBlock block = cursor.block();
            observations.append(QJsonObject{{QStringLiteral("label"), label},
                {QStringLiteral("scroll_to_target"), scrollToTarget}, {QStringLiteral("offset"), offset},
                {QStringLiteral("same_character_text"), sameText},
                {QStringLiteral("reported_screen_rect"), rectJson(reported)},
                {QStringLiteral("cursor_screen_rect"), rectJson(screen)},
                {QStringLiteral("block_local_layout_rect"), rectJson(block.layout()->boundingRect().translated(block.layout()->position()))},
                {QStringLiteral("block_document_rect"), rectJson(browser->document()->documentLayout()->blockBoundingRect(block))},
                {QStringLiteral("vertical_scroll"), browser->verticalScrollBar()->value()},
                {QStringLiteral("horizontal_scroll"), browser->horizontalScrollBar()->value()},
                {QStringLiteral("geometry_required"), geometryRequired},
                {QStringLiteral("cursor_intersects_viewport"), cursorVisible},
                {QStringLiteral("reported_intersects_cursor"), intersects}});
            matches.append(sameText && (!geometryRequired || intersects) && (!scrollToTarget || cursorVisible));
            return true;
        };
        QVERIFY(observe(QStringLiteral("RootProbe"), false));
        QVERIFY(observe(QStringLiteral("NestedProbe"), false));
        QVERIFY(observe(QStringLiteral("NestedProbe"), true));
        QVERIFY(observe(QStringLiteral("AfterProbe"), true));
        const QString reportPath = qEnvironmentVariable("DICT_QT_ACCESSIBILITY_GEOMETRY_REPORT");
        if (!reportPath.isEmpty()) {
            QFile report(reportPath); QVERIFY(report.open(QIODevice::WriteOnly | QIODevice::NewOnly));
            const QJsonObject result{{QStringLiteral("scope"), QStringLiteral("Installed Qt/current MainWindow reader synthetic geometry; no corpus or pointer activation acceptance")},
                {QStringLiteral("qt_version"), QString::fromLatin1(qVersion())},
                {QStringLiteral("observations"), observations}};
            QVERIFY(report.write(QJsonDocument(result).toJson()) > 0);
        }
        QCOMPARE(matches.size(), 4);
        QCOMPARE(observations[1].toObject().value(QStringLiteral("vertical_scroll")).toInt(), 0);
        QVERIFY(observations[2].toObject().value(QStringLiteral("vertical_scroll")).toInt() > 0);
        QVERIFY(observations[2].toObject().value(QStringLiteral("vertical_scroll")) != observations[1].toObject().value(QStringLiteral("vertical_scroll")));
        QVERIFY(observations[2].toObject().value(QStringLiteral("cursor_intersects_viewport")).toBool());
        QVERIFY(observations[3].toObject().value(QStringLiteral("cursor_intersects_viewport")).toBool());
        for (qsizetype i = 0; i < matches.size(); ++i)
            QVERIFY2(matches[i], qPrintable(QString::fromUtf8(QJsonDocument(observations[i].toObject()).toJson(QJsonDocument::Compact))));
    }

    void readerAccessibilityPreservesTextStylesSelectionAndGraphemeCoordinates() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        browser->setHtml(QString::fromUtf8(
            "<p><b><i>BoldWord</i></b> PlainWord e\xcc\x81 \xf0\x9f\x98\x80</p>"
            "<p>תשרק plain</p>"
            "<p>A wrapped accessible line with several additional words that must continue beyond one visual row.</p>"
            "<table border='1' width='1400'><tr><td width='1100' dir='rtl'>אבגדה</td>"
            "<td>WideProbe</td></tr></table><p>TailProbe</p>"));
        QApplication::processEvents();
        auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible);
        QCOMPARE(accessible->role(), QAccessible::StaticText);
        QCOMPARE(accessible->text(QAccessible::Name), QStringLiteral("Dictionary entry"));
        QVERIFY(accessible->state().readOnly); QVERIFY(accessible->state().multiLine);
        QVERIFY(accessible->state().selectableText); QVERIFY(!accessible->state().editable);
        QVERIFY(accessible->actionInterface());
        QVERIFY(accessible->actionInterface()->actionNames().contains(QAccessibleActionInterface::setFocusAction()));
        auto *text = accessible->textInterface(); QVERIFY(text);
        auto *editable = accessible->editableTextInterface(); QVERIFY(editable);
        QCOMPARE(text->characterCount(), browser->document()->characterCount() - 1);
        QTextCursor all(browser->document()); all.select(QTextCursor::Document);
        const QString original = all.selectedText().replace(QChar(QChar::ParagraphSeparator), QChar('\n'));
        QCOMPARE(text->text(0, -1), original);
        const auto bold = browser->document()->find(QStringLiteral("BoldWord")); QVERIFY(!bold.isNull());
        int start = -1, end = -1;
        const QString attrs = text->attributes(bold.selectionStart(), &start, &end);
        QVERIFY(attrs.contains(QStringLiteral("font-weight:700;")));
        QVERIFY(attrs.contains(QStringLiteral("font-style:italic;")));
        QVERIFY(start <= bold.selectionStart() && end >= bold.selectionEnd());
        text->setSelection(0, bold.selectionStart(), bold.selectionEnd());
        QCOMPARE(text->selectionCount(), 1); text->selection(0, &start, &end);
        QCOMPARE(start, bold.selectionStart()); QCOMPARE(end, bold.selectionEnd());
        QCOMPARE(text->text(start, end), QStringLiteral("BoldWord"));
        text->removeSelection(0); QCOMPARE(text->selectionCount(), 0);
        text->setCursorPosition(bold.selectionStart() + 2);
        QCOMPARE(text->cursorPosition(), bold.selectionStart() + 2);
        const QString word = text->textAtOffset(-2, QAccessible::WordBoundary, &start, &end);
        QCOMPARE(word, QStringLiteral("BoldWord"));
        editable->insertText(0, QStringLiteral("MUST NOT EDIT READONLY"));
        editable->deleteText(0, 1); editable->replaceText(0, 1, QStringLiteral("X"));
        QCOMPARE(text->text(0, -1), original);
        const auto wrapped = browser->document()->find(QStringLiteral("A wrapped accessible line")); QVERIFY(!wrapped.isNull());
        const auto wrappedBlock = wrapped.block();
        browser->document()->documentLayout()->blockBoundingRect(wrappedBlock);
        QVERIFY(wrappedBlock.layout()->lineCount() > 1);
        const auto secondLine = wrappedBlock.layout()->lineAt(1);
        const int lineStart = wrappedBlock.position() + secondLine.textStart();
        QCOMPARE(text->textAtOffset(lineStart + 1, QAccessible::LineBoundary, &start, &end),
                 text->text(lineStart, lineStart + secondLine.textLength()));
        QCOMPARE(start, lineStart); QCOMPARE(end, lineStart + secondLine.textLength());
        const auto emoji = browser->document()->find(QString::fromUtf8("\xf0\x9f\x98\x80")); QVERIFY(!emoji.isNull());
        text->scrollToSubstring(emoji.selectionStart(), emoji.selectionEnd());
        QVERIFY(text->characterRect(emoji.selectionStart()).width() > 1);
        QCOMPARE(text->characterRect(emoji.selectionStart()), text->characterRect(emoji.selectionStart() + 1));
        const auto combining = browser->document()->find(QString::fromUtf8("e\xcc\x81")); QVERIFY(!combining.isNull());
        QVERIFY(text->characterRect(combining.selectionStart()).width() > 1);
        QCOMPARE(text->characterRect(combining.selectionStart()), text->characterRect(combining.selectionStart() + 1));
        auto autoRtl = browser->document()->find(QString::fromUtf8("תשרק")); QVERIFY(!autoRtl.isNull());
        auto autoFormat = autoRtl.blockFormat(); autoFormat.setLayoutDirection(Qt::LayoutDirectionAuto);
        autoRtl.setBlockFormat(autoFormat);
        QCOMPARE(autoRtl.block().blockFormat().layoutDirection(), Qt::LayoutDirectionAuto);
        QCOMPARE(autoRtl.block().textDirection(), Qt::RightToLeft);
        QVERIFY(text->attributes(autoRtl.selectionStart(), &start, &end).contains(QStringLiteral("direction:rtl;")));
        const auto rtl = browser->document()->find(QString::fromUtf8("אבגדה")); QVERIFY(!rtl.isNull());
        const int rtlOffset = rtl.selectionStart() + 2;
        QCOMPARE(text->textAtOffset(rtlOffset, QAccessible::ParagraphBoundary, &start, &end), QString::fromUtf8("אבגדה"));
        QCOMPARE(start, rtl.block().position()); QCOMPARE(end, rtl.block().position() + rtl.block().length() - 1);
        text->setSelection(0, bold.selectionStart(), bold.selectionEnd());
        const auto savedSelection = browser->textCursor();
        text->scrollToSubstring(rtlOffset, rtlOffset + 1);
        QCOMPARE(browser->textCursor().selectionStart(), savedSelection.selectionStart());
        QCOMPARE(browser->textCursor().selectionEnd(), savedSelection.selectionEnd());
        QTextCursor rtlCursor(browser->document()); rtlCursor.setPosition(rtlOffset);
        const QRect caret = browser->cursorRect(rtlCursor);
        const QRect reported = text->characterRect(rtlOffset);
        QTextCursor rtlNext(browser->document()); rtlNext.setPosition(rtlOffset + 1);
        const QRect nextCaret = browser->cursorRect(rtlNext);
        const QPoint glyphCenter = browser->viewport()->mapToGlobal(
            QPoint((caret.x() + nextCaret.x()) / 2, caret.center().y()));
        QVERIFY(reported.contains(glyphCenter));
        QVERIFY(browser->viewport()->rect().contains(caret.center()));
        const int hit = text->offsetAtPoint(glyphCenter);
        QVERIFY(hit >= rtlOffset && hit <= rtlOffset + 1);
        const auto wide = browser->document()->find(QStringLiteral("WideProbe")); QVERIFY(!wide.isNull());
        QVERIFY(browser->horizontalScrollBar()->maximum() > 0);
        text->scrollToSubstring(wide.selectionStart(), wide.selectionEnd());
        QVERIFY(browser->horizontalScrollBar()->value() > 0);
        QTextCursor wideCursor(browser->document()); wideCursor.setPosition(wide.selectionStart());
        const QRect wideCaret = browser->cursorRect(wideCursor);
        const QRect wideScreen(browser->viewport()->mapToGlobal(wideCaret.topLeft()), wideCaret.size());
        QVERIFY(text->characterRect(wide.selectionStart()).intersects(wideScreen));
        QVERIFY(browser->viewport()->rect().contains(wideCaret.center()));
        QCOMPARE(text->text(0, -1), original);
    }

    void readerAccessibilityPreservesLegacyAttributeOffsetsAndSeparatorRuns() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        QTextBrowser legacy;
        const QString html = QStringLiteral("<p><b>BoldWord</b> <i>ItalicTail</i></p><p>Next</p>");
        browser->setHtml(html); legacy.setHtml(html);
        auto *currentAccessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(currentAccessible);
        auto *legacyAccessible = QAccessible::queryAccessibleInterface(&legacy); QVERIFY(legacyAccessible);
        auto *current = currentAccessible->textInterface(); QVERIFY(current);
        auto *original = legacyAccessible->textInterface(); QVERIFY(original);
        QCOMPARE(current->characterCount(), original->characterCount());
        const auto observe = [](QAccessibleTextInterface *text, int offset) {
            int start = 123456, end = 123456;
            const QString value = text->attributes(offset, &start, &end);
            return QJsonObject{{QStringLiteral("value"), value}, {QStringLiteral("start"), start}, {QStringLiteral("end"), end}};
        };
        const QString originalText = current->text(0, -1);
        auto selection = browser->document()->find(QStringLiteral("BoldWord")); QVERIFY(!selection.isNull());
        selection.setPosition(selection.selectionStart() + 1);
        selection.setPosition(selection.position() + 2, QTextCursor::KeepAnchor);
        browser->setTextCursor(selection);
        const int selectedPosition = selection.position(), selectedAnchor = selection.anchor();
        const auto positive = observe(current, selectedPosition);
        QVERIFY(positive.value(QStringLiteral("value")).toString().contains(QStringLiteral("font-weight:700;")));
        QCOMPARE(observe(current, -2), positive);
        QCOMPARE(browser->textCursor().position(), selectedPosition);
        QCOMPARE(browser->textCursor().anchor(), selectedAnchor);
        auto legacySelection = legacy.textCursor(); legacySelection.setPosition(selectedAnchor);
        legacySelection.setPosition(selectedPosition, QTextCursor::KeepAnchor); legacy.setTextCursor(legacySelection);
        QCOMPARE(observe(original, -2), observe(original, selectedPosition));
        // Real installed Qt establishes the separator range/format contract independently.
        const auto block = browser->document()->begin();
        const int separator = block.position() + block.length() - 1;
        const auto expectedSeparator = observe(original, separator);
        const auto actualSeparator = observe(current, separator);
        QCOMPARE(expectedSeparator.value(QStringLiteral("start")).toInt(), separator);
        QCOMPARE(expectedSeparator.value(QStringLiteral("end")).toInt(), separator + 1);
        QCOMPARE(actualSeparator.value(QStringLiteral("start")), expectedSeparator.value(QStringLiteral("start")));
        QCOMPARE(actualSeparator.value(QStringLiteral("end")), expectedSeparator.value(QStringLiteral("end")));
        const bool legacyItalic = expectedSeparator.value(QStringLiteral("value")).toString().contains(QStringLiteral("font-style:italic;"));
        QCOMPARE(actualSeparator.value(QStringLiteral("value")).toString().contains(QStringLiteral("font-style:italic;")), legacyItalic);
        QVERIFY(!legacyItalic);
        QCOMPARE(browser->textCursor().position(), selectedPosition);
        QCOMPARE(browser->textCursor().anchor(), selectedAnchor);
        const int count = current->characterCount(); QVERIFY(count > 0);
        current->setCursorPosition(count); original->setCursorPosition(count);
        const auto last = observe(current, count - 1);
        for (const int offset : {-1, count, -2}) {
            QCOMPARE(observe(current, offset), last);
            QCOMPARE(observe(original, offset), observe(original, count - 1));
        }
        QCOMPARE(current->cursorPosition(), count); QCOMPARE(current->selectionCount(), 0);
        for (const int offset : {-3, count + 1}) {
            const auto invalid = observe(current, offset);
            QVERIFY(invalid.value(QStringLiteral("value")).toString().isEmpty());
            QCOMPARE(invalid.value(QStringLiteral("start")).toInt(), -1);
            QCOMPARE(invalid.value(QStringLiteral("end")).toInt(), -1);
        }
        QCOMPARE(current->text(0, -1), originalText); QCOMPARE(current->cursorPosition(), count);
        browser->clear(); legacy.clear(); QCOMPARE(current->characterCount(), 0);
        for (const int offset : {-3, -2, -1, 0, 1}) {
            const auto empty = observe(current, offset);
            QVERIFY(empty.value(QStringLiteral("value")).toString().isEmpty());
            QCOMPARE(empty.value(QStringLiteral("start")).toInt(), -1);
            QCOMPARE(empty.value(QStringLiteral("end")).toInt(), -1);
            QCOMPARE(empty, observe(original, offset));
        }
        QCOMPARE(current->cursorPosition(), 0); QCOMPARE(current->selectionCount(), 0);
    }

    void readerAccessibilityUsesCharacterEdgesAtWrapAndBidiBoundaries() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        browser->setWordWrapMode(QTextOption::WrapAnywhere);
        browser->setPlainText(QString(150, QChar('W')) + QString::fromUtf8("\nLeft אבגדה Right"));
        QApplication::processEvents();
        auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible);
        auto *text = accessible->textInterface(); QVERIFY(text);
        const auto expectedRect = [&](int offset) {
            const auto block = browser->document()->findBlock(offset);
            const QRectF absolute = browser->document()->documentLayout()->blockBoundingRect(block);
            const auto line = block.layout()->lineForTextPosition(offset - block.position());
            const qreal a = line.cursorToX(offset - block.position(), QTextLine::Leading);
            const qreal b = line.cursorToX(offset - block.position(), QTextLine::Trailing);
            QRectF rect(absolute.left() + qMin(a, b), absolute.top() + line.y(), qAbs(b - a), line.height());
            rect.translate(browser->viewport()->mapToGlobal(QPoint())
                - QPoint(browser->horizontalScrollBar()->value(), browser->verticalScrollBar()->value()));
            return rect.toAlignedRect();
        };
        auto block = browser->document()->begin();
        browser->document()->documentLayout()->blockBoundingRect(block);
        QVERIFY(block.layout()->lineCount() > 1);
        const auto firstLine = block.layout()->lineAt(0);
        const int finalOffset = block.position() + firstLine.textStart() + firstLine.textLength() - 1;
        QTextCursor first(browser->document()); first.setPosition(finalOffset);
        QTextCursor next(browser->document()); next.setPosition(finalOffset + 1);
        QVERIFY(browser->cursorRect(first).y() != browser->cursorRect(next).y());
        text->scrollToSubstring(finalOffset, finalOffset + 1);
        QVERIFY(expectedRect(finalOffset).width() > 1);
        QCOMPARE(text->characterRect(finalOffset), expectedRect(finalOffset));
        const auto rtl = browser->document()->find(QString::fromUtf8("אבגדה")); QVERIFY(!rtl.isNull());
        const int bidiOffset = rtl.selectionEnd() - 1;
        text->scrollToSubstring(bidiOffset, bidiOffset + 1);
        first.setPosition(bidiOffset); next.setPosition(bidiOffset + 1);
        const int unrelatedCaretDistance = qAbs(browser->cursorRect(next).x() - browser->cursorRect(first).x());
        QVERIFY(unrelatedCaretDistance > expectedRect(bidiOffset).width() * 2);
        QCOMPARE(text->characterRect(bidiOffset), expectedRect(bidiOffset));
        QVERIFY(text->characterRect(bidiOffset).width() < unrelatedCaretDistance);
    }

    void settledReaderLayoutMatchesContentWidthAcrossBothResizeDirections() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QJsonArray observations;
        int step = 0;
        for (const int width : {580, 780, 1100, 780, 580}) {
            window.resize(width, 480);
            QTest::qWait(100); // Process the real child resize/layout events; never call updateReaderLayout directly.
            qInfo().noquote() << "SETTLED_READER_PRESELECTION" << QJsonDocument(QJsonObject{
                {"step", step}, {"window_width", window.width()}, {"compact_navigation", window.compactNavigation_},
                {"reader_visible", window.readerContent_->isVisible()}, {"reader_hidden", window.readerContent_->isHidden()},
                {"search_visible", window.searchPane_->isVisible()}, {"back_visible", window.back_->isVisible()},
                {"back_hidden", window.back_->isHidden()}}).toJson(QJsonDocument::Compact);
            if (window.compactNavigation_) {
                QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
                const QString frame = QDir::current().filePath(QStringLiteral(".tmp/ui-screenshots/desktop-settled-layout-preselection-%1-%2-%3.png")
                    .arg(QCoreApplication::applicationPid()).arg(step).arg(width));
                QVERIFY(window.grab().save(frame));
                qInfo().noquote() << "SETTLED_READER_PRESELECTION_FRAME" << frame;
                // This test measures the reading surface; choose it through the
                // production action when compact navigation shows one pane.
                window.readingPaneAction_->trigger();
                QTRY_VERIFY(window.readerContent_->isVisible());
                QTRY_VERIFY(!window.searchPane_->isVisible());
                QTest::qWait(100);
            }
            QTRY_VERIFY(window.readerContent_->isVisible());
            QTRY_COMPARE(window.compactReader_, window.readerContent_->width() < 580);
            const bool compact = window.readerContent_->width() < 580;
            int row = -1, column = -1, rowSpan = -1, columnSpan = -1;
            window.navigationLayout_->getItemPosition(window.navigationLayout_->indexOf(window.sections_), &row, &column, &rowSpan, &columnSpan);
            QCOMPARE(row, compact ? 1 : 0); QCOMPARE(column, compact ? 0 : 2);
            QCOMPARE(columnSpan, compact ? 2 : 1);
            const QRect contentGeometry = window.readerContent_->geometry();
            const QRect jumpGeometry = window.sections_->geometry();
            QTest::qWait(100);
            QCOMPARE(window.readerContent_->geometry(), contentGeometry);
            QCOMPARE(window.sections_->geometry(), jumpGeometry);
            QCOMPARE(window.compactReader_, compact);
            window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("cat"), Qt::CaseInsensitive));
            for (QWidget *control : std::array<QWidget *, 5>{window.back_, window.forward_, window.sections_, window.smaller_, window.larger_}) {
                QVERIFY(control->isVisible()); QVERIFY(window.readerContent_->rect().contains(control->geometry()));
            }
            observations.append(QJsonObject{{QStringLiteral("step"), step}, {QStringLiteral("window_width"), window.width()},
                {QStringLiteral("content_width"), window.readerContent_->width()}, {QStringLiteral("compact"), compact},
                {QStringLiteral("jump_row"), row}, {QStringLiteral("jump_column"), column},
                {QStringLiteral("jump_colspan"), columnSpan}, {QStringLiteral("reading_focus"), window.reading_->hasFocus()}});
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-settled-layout-%1-%2.png").arg(step++).arg(width)));
        }
        bool sawCompact = false, sawWide = false;
        int transitions = 0;
        for (qsizetype i = 0; i < observations.size(); ++i) {
            const bool compact = observations[i].toObject().value(QStringLiteral("compact")).toBool();
            sawCompact |= compact; sawWide |= !compact;
            if (i > 0 && compact != observations[i - 1].toObject().value(QStringLiteral("compact")).toBool()) ++transitions;
        }
        QVERIFY(sawCompact && sawWide); QVERIFY(transitions >= 2);
        QFile report(QStringLiteral(".tmp/ui-screenshots/desktop-settled-layout.json"));
        QVERIFY(report.open(QIODevice::WriteOnly));
        QVERIFY(report.write(QJsonDocument(observations).toJson()) > 0);
    }

    void selfOnlyHeadingCompanionRetainsStylesWithoutDuplicateOrAction() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QJsonObject decoded = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object()
            .value(QStringLiteral("entries")).toArray().first().toObject();
        const QJsonObject self{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("text"), QStringLiteral("Self heading")}, {QStringLiteral("target"), QString()},
            {QStringLiteral("classes"), QStringLiteral("mw-selflink selflink")},
            {QStringLiteral("bold"), true}, {QStringLiteral("italic"), true}};
        const auto render = [&](const QJsonObject &span, int level = 3, const QString &title = QStringLiteral("Self heading")) {
            QJsonObject entry = decoded;
            entry.insert(QStringLiteral("preamble_spans"), QJsonArray{}); entry.insert(QStringLiteral("references"), QJsonArray{});
            const QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")},
                {QStringLiteral("level"), level}, {QStringLiteral("spans"), QJsonArray{span}}};
            const QJsonObject bodySpan{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QStringLiteral("Visible body")}};
            const QJsonObject body{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{bodySpan}}};
            const QJsonArray blocks{heading, body};
            const QJsonObject section{{QStringLiteral("title"), title}, {QStringLiteral("level"), 3},
                {QStringLiteral("blocks"), blocks}};
            entry.insert(QStringLiteral("sections"), QJsonArray{section});
            return window.entryHtml(entry);
        };
        for (bool bold : {true, false}) {
            QJsonObject span = self; span.insert(QStringLiteral("bold"), bold);
            span.insert(QStringLiteral("classes"), QStringLiteral("note\tmw-selflink\nselflink extra"));
            QTextDocument doc; doc.setHtml(render(span));
            QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 1);
            const QTextCursor found = doc.find(QStringLiteral("Self heading")); QVERIFY(!found.isNull());
            QVERIFY(found.charFormat().fontItalic());
            QVERIFY(!found.charFormat().isAnchor()); QVERIFY(found.charFormat().anchorHref().isEmpty());
            if (bold) QVERIFY(found.charFormat().fontWeight() >= QFont::Bold);
            QVERIFY(doc.toPlainText().contains(QStringLiteral("Visible body")));
            if (bold) {
                // Explicit client-only heading render; no imported corpus entry.
                for (const int width : {580, 780}) {
                    window.resize(width, 480); window.reading_->setHtml(render(span));
                    window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
                    QCOMPARE(window.size(), QSize(width, 480));
                    QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Self heading")), 1);
                    const QTextCursor heading = window.reading_->document()->find(QStringLiteral("Self heading"));
                    QVERIFY(!heading.isNull() && !heading.charFormat().isAnchor());
                    QVERIFY(heading.charFormat().fontItalic());
                    QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
                    QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-client-selfheading-%1.png").arg(width)));
                }
            }
        }
        for (const QString &classes : {QString(), QStringLiteral("mw-selflink"), QStringLiteral("selflink"),
             QStringLiteral("not-mw-selflink selflink"), QStringLiteral("mw-selflink selflink-suffix")}) {
            QJsonObject span = self; span.insert(QStringLiteral("classes"), classes);
            QTextDocument doc; doc.setHtml(render(span));
            QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 1);
        }
        // Each compiled style/semantic field independently makes an unlinked companion rich.
        const QJsonObject plain{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("text"), QStringLiteral("Self heading")}};
        QList<QJsonObject> styles;
        for (const QString &flag : {QStringLiteral("bold"), QStringLiteral("italic"), QStringLiteral("code"),
             QStringLiteral("small"), QStringLiteral("superscript"), QStringLiteral("subscript"),
             QStringLiteral("strike"), QStringLiteral("underline")})
            styles.append(QJsonObject{{flag, true}});
        styles.append(QJsonObject{{QStringLiteral("foreground"), QStringLiteral("#123456")}});
        styles.append(QJsonObject{{QStringLiteral("classes"), QStringLiteral("note")}});
        styles.append(QJsonObject{{QStringLiteral("language"), QStringLiteral("fr")}});
        styles.append(QJsonObject{{QStringLiteral("direction"), QStringLiteral("rtl")}});
        styles.append(QJsonObject{{QStringLiteral("role"), QStringLiteral("label")}});
        for (const QJsonObject &style : styles) {
            QJsonObject span = plain;
            for (auto i = style.begin(); i != style.end(); ++i) span.insert(i.key(), i.value());
            QTextDocument doc; doc.setHtml(render(span));
            QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 1);
            QVERIFY(doc.find(QStringLiteral("Self heading")).charFormat().anchorHref().isEmpty());
            doc.setHtml(render(span, 2)); QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 2);
            span.insert(QStringLiteral("target"), QStringLiteral("other"));
            doc.setHtml(render(span)); QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 2);
        }
        QTextDocument plainDocument; plainDocument.setHtml(render(plain));
        QCOMPARE(plainDocument.toPlainText().count(QStringLiteral("Self heading")), 2);
        QJsonObject italicOnly = plain; italicOnly.insert(QStringLiteral("italic"), true);
        window.resize(780, 480); window.reading_->setHtml(render(italicOnly));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Self heading")), 1);
        const QTextCursor styledHeading = window.reading_->document()->find(QStringLiteral("Self heading"));
        QVERIFY(styledHeading.charFormat().fontItalic());
        QVERIFY(styledHeading.charFormat().anchorHref().isEmpty());
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-client-styled-unlinked-heading-780.png")));
        QJsonObject targeted = self; targeted.insert(QStringLiteral("target"), QStringLiteral("other"));
        QTextDocument invalid; invalid.setHtml(render(targeted)); QCOMPARE(invalid.toPlainText().count(QStringLiteral("Self heading")), 2);
        invalid.setHtml(render(self, 2)); QCOMPARE(invalid.toPlainText().count(QStringLiteral("Self heading")), 2);
        invalid.setHtml(render(self, 3, QStringLiteral("Different"))); QCOMPARE(invalid.toPlainText().count(QStringLiteral("Self heading")), 1);
    }

    void richHeadingCompanionMatchesOnlyExactFirstCanonicalLabel() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QJsonObject decoded = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object()
            .value(QStringLiteral("entries")).toArray().first().toObject();
        const auto span = [](const QString &kind, const QString &text, const QString &target = QString(), const QString &trail = QString()) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text},
                {QStringLiteral("target"), target}, {QStringLiteral("trail"), trail}};
        };
        const auto heading = [](const QJsonArray &spans, int level = 3, const QString &kind = QStringLiteral("heading")) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("depth"), 0}, {QStringLiteral("level"), level}, {QStringLiteral("spans"), spans}};
        };
        const QJsonObject linked = span(QStringLiteral("link"), QStringLiteral("Notes"), QStringLiteral("notes"));
        const auto check = [&](const QJsonArray &blocks, int count, const QString &name = QStringLiteral("Notes")) {
            QJsonObject entry = decoded;
            entry.insert(QStringLiteral("preamble_spans"), QJsonArray{});
            entry.insert(QStringLiteral("references"), QJsonArray{});
            entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), name},
                {QStringLiteral("level"), 3}, {QStringLiteral("blocks"), blocks}}});
            window.collapsedSections_.clear();
            QTextDocument document;
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(document.toPlainText().count(QStringLiteral("Notes")), count);
        };
        check(QJsonArray{heading(QJsonArray{linked})}, 1);
        QJsonObject nestedDepth = heading(QJsonArray{linked});
        nestedDepth.insert(QStringLiteral("depth"), 5);
        check(QJsonArray{nestedDepth}, 1);
        nestedDepth.insert(QStringLiteral("depth"), 3);
        nestedDepth.insert(QStringLiteral("level"), 0);
        check(QJsonArray{nestedDepth}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("text"), QStringLiteral("\u00a0 \t")),
            linked, span(QStringLiteral("line_break"), QStringLiteral("ignored")), span(QStringLiteral("text"), QStringLiteral("\r "))})}, 1);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("external_link"), QStringLiteral("Notes"), QStringLiteral("https://example.org/notes"))})}, 1);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), {}, QStringLiteral("notes"), QStringLiteral("Notes"))})}, 1);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("\u2003Notes"), QStringLiteral("notes"))})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("\u2003Notes"), QStringLiteral("notes"))})}, 1, QStringLiteral("\u2003Notes"));
        check(QJsonArray{heading(QJsonArray{linked}, 2)}, 2);
        check(QJsonArray{heading(QJsonArray{linked}, 3, QStringLiteral("paragraph"))}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("Notes"))})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("text"), QStringLiteral("Notes"), QStringLiteral("notes"))})}, 2);
        check(QJsonArray{heading(QJsonArray{linked, span(QStringLiteral("line_break"), QStringLiteral("\n"), {}, QStringLiteral("extra"))})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("text"), QStringLiteral("Before"))}, 0, QStringLiteral("paragraph")),
            heading(QJsonArray{linked})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("Different Notes"), QStringLiteral("notes"))})}, 2);
    }

    void blankSectionHeadingsKeepBodyReachableAfterRetainedFolds() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.learning_.setCollapseEtymology(true);
        const QJsonObject originalResponse = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        const QJsonObject originalEntry = originalResponse.value(QStringLiteral("entries")).toArray().first().toObject();
        const QJsonArray originalSections = originalEntry.value(QStringLiteral("sections")).toArray();
        int nounIndex = -1, etymologyIndex = -1;
        for (qsizetype i = 0; i < originalSections.size(); ++i) {
            const QString heading = originalSections[i].toObject().value(QStringLiteral("title")).toString();
            if (heading == QStringLiteral("Noun")) nounIndex = int(i);
            if (heading == QStringLiteral("Etymology")) etymologyIndex = int(i);
        }
        QVERIFY(nounIndex >= 0 && etymologyIndex >= 0);
        const QString nounToggle = QStringLiteral("section:%1").arg(nounIndex);
        const QString etymologyToggle = QStringLiteral("section:%1").arg(etymologyIndex);
        for (const QString &heading : {QString(), QStringLiteral(" \t\n ")}) {
            QJsonObject response = originalResponse, entry = originalEntry;
            QJsonArray sections = originalSections;
            QJsonObject noun = sections[nounIndex].toObject();
            noun.insert(QStringLiteral("title"), heading);
            sections[nounIndex] = noun;
            entry.insert(QStringLiteral("sections"), sections);
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson());

            QVERIFY(!window.collapsedSections_.contains(nounIndex));
            QVERIFY(window.collapsedSections_.contains(etymologyIndex));
            QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-%1").arg(nounIndex)));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("The cat sleeps.")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Inflection table")));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));

            // Unlike the Android heading, the desktop keeps a real chevron even with no label.
            QVERIFY(clickAnchor(window.reading_, nounToggle));
            QVERIFY(window.collapsedSections_.contains(nounIndex));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            const QSet<int> retained = window.collapsedSections_;
            window.collapsedSections_.clear(); window.refreshReading();
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            window.collapsedSections_ = retained; window.refreshReading();
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            QVERIFY(clickAnchor(window.reading_, nounToggle));
            QVERIFY(!window.collapsedSections_.contains(nounIndex));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("écoles")).charFormat().anchorHref(),
                QStringLiteral("dict:%C3%A9cole"));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));

            // An ordinary named heading still folds and reopens independently.
            QVERIFY(clickAnchor(window.reading_, etymologyToggle));
            QVERIFY(!window.collapsedSections_.contains(etymologyIndex));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        }
    }

    void compiledPreformattedTextPreservesIndentationTabsAndLineBreaks() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QString expected = QStringLiteral("column A  column B\n  indented\tvalue");
        QJsonArray preformatted;
        for (const QJsonValue &section : window.currentEntry_.value(QStringLiteral("sections")).toArray()) {
            for (const QJsonValue &block : section.toObject().value(QStringLiteral("blocks")).toArray()) {
                if (block.toObject().value(QStringLiteral("kind")).toString() == QStringLiteral("preformatted"))
                    preformatted.append(block);
            }
        }
        QCOMPARE(preformatted.size(), 1);
        const QJsonArray spans = preformatted.first().toObject().value(QStringLiteral("spans")).toArray();
        QCOMPARE(spans.size(), 1);
        QCOMPARE(spans.first().toObject().value(QStringLiteral("text")).toString(), expected);
        QCOMPARE(spans.first().toObject().value(QStringLiteral("trail")).toString(), QString());

        QPushButton *larger = nullptr;
        for (auto *button : window.findChildren<QPushButton *>())
            if (button->accessibleName() == QStringLiteral("Larger reading text")) larger = button;
        QVERIFY(larger);
        const int initialSize = window.readingPointSize_;
        for (int phase = 0; phase < 2; ++phase) {
            const QString plain = window.reading_->document()->toPlainText();
            const qsizetype start = plain.indexOf(QStringLiteral("column A"));
            QVERIFY(start >= 0);
            QCOMPARE(plain.mid(start, expected.size()), expected);
            QCOMPARE(plain.count(expected), 1);
            if (phase == 0) QTest::mouseClick(larger, Qt::LeftButton);
        }
        QVERIFY(window.readingPointSize_ > initialSize);
    }

    void semanticReadingZoomAndThemes() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTextDocument *document = window.reading_->document();
        const QString text = document->toPlainText();
        QVERIFY(text.contains(QStringLiteral("Example: The cat sleeps.")));
        QVERIFY(!text.contains(QStringLiteral("Example:The cat sleeps.")));
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
        const auto paintedTitleInk = [&] {
            const QImage frame = window.title_->viewport()->grab().toImage();
            const QColor ink = window.palette().color(QPalette::Text);
            int pixels = 0;
            for (int y = 0; y < frame.height(); ++y) {
                for (int x = 0; x < frame.width(); ++x) {
                    const QColor pixel = frame.pixelColor(x, y);
                    if (qAbs(pixel.red() - ink.red()) <= 12 &&
                        qAbs(pixel.green() - ink.green()) <= 12 &&
                        qAbs(pixel.blue() - ink.blue()) <= 12) ++pixels;
                }
            }
            return pixels;
        };
        window.learning_.setTheme(QStringLiteral("light"));
        window.applyTheme();
        const QColor lightInk = window.palette().color(QPalette::Text);
        QCOMPARE(window.title_->palette().color(QPalette::Text), lightInk);
        QVERIFY2(paintedTitleInk() > 20, "Light title must paint readable theme ink");
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-light.png")));
        window.learning_.setTheme(QStringLiteral("dark"));
        window.applyTheme();
        QVERIFY(window.palette().color(QPalette::Text) != lightInk);
        QCOMPARE(window.title_->palette().color(QPalette::Text), window.palette().color(QPalette::Text));
        QVERIFY2(paintedTitleInk() > 20, "Dark title must paint readable theme ink");
        QCOMPARE(window.reading_->document()->toPlainText(), text);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("A small animal.")).charFormat().foreground().color(), window.palette().color(QPalette::Text));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-dark.png")));
        window.learning_.setTheme(QStringLiteral("light"));
        window.applyTheme();
        QCOMPARE(window.title_->palette().color(QPalette::Text), lightInk);
        QVERIFY2(paintedTitleInk() > 20, "Title ink must follow a second theme switch");
        QCOMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.reading_->document()->toPlainText(), text);
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
